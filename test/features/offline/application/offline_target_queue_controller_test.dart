import 'dart:async';
import 'dart:io';

import 'package:easy_cloud/features/browser/application/browser_repository.dart';
import 'package:easy_cloud/features/browser/domain/cloud_folder_page.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:easy_cloud/features/download/application/download_repository.dart';
import 'package:easy_cloud/features/download/domain/download.dart';
import 'package:easy_cloud/features/offline/application/offline_target_index.dart';
import 'package:easy_cloud/features/offline/application/offline_target_queue_controller.dart';
import 'package:easy_cloud/features/offline/data/sqlite_offline_file_index.dart';
import 'package:easy_cloud/features/offline/domain/offline_target.dart';
import 'package:easy_cloud/local/cache/application_cache_root.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('scans breadth first, paginates at 100, and reaches ready', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-queue');
    final index = _index(root);
    final browser = _Browser((path, offset) {
      if (path == '/root' && offset == 0) {
        return _page('/root', [
          _folder('/root/sub'),
          _file('/root/a.txt'),
        ], total: 2);
      }
      if (path == '/root/sub' && offset == 0) {
        return _page('/root/sub', [_file('/root/sub/b.txt')], total: 1);
      }
      throw StateError('unexpected page $path@$offset');
    });
    final downloads = _TargetDownloads(index);
    final queue = OfflineTargetQueueController(
      targetIndex: index,
      browserRepository: browser,
      downloadRepository: downloads,
      queueStore: index,
    );
    addTearDown(() async {
      await queue.close();
      await index.close();
      await root.delete(recursive: true);
    });

    await queue.attach('user@mail.ru');
    await queue.enqueue(_folder('/root'));
    await _waitUntil(() async {
      final target = await index.getTarget('user@mail.ru', '/root');
      return target?.state == OfflineTargetState.ready;
    });

    expect(browser.calls, ['/root@0', '/root/sub@0']);
    expect(downloads.paths, ['/root/a.txt', '/root/sub/b.txt']);
    expect(
      (await index.listTargetFiles('user@mail.ru', '/root')),
      everyElement(
        isA<OfflineTargetFileRecord>().having(
          (file) => file.readiness,
          'readiness',
          OfflineReadiness.ready,
        ),
      ),
    );
  });

  test(
    'advances a full page by accepted items and terminates on a short page',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-pages');
      final index = _index(root);
      final items = List.generate(101, (number) => _file('/root/file-$number'));
      final browser = _Browser((path, offset) {
        final pageItems = offset == 0
            ? items.take(100).toList()
            : items.skip(offset).toList();
        return _page(path, pageItems, total: 101);
      });
      final queue = OfflineTargetQueueController(
        targetIndex: index,
        browserRepository: browser,
        downloadRepository: _TargetDownloads(index),
        queueStore: index,
      );
      addTearDown(() async {
        await queue.close();
        await index.close();
        await root.delete(recursive: true);
      });

      await queue.attach('user@mail.ru');
      await queue.enqueue(_folder('/root'));
      await _waitUntil(() async {
        final target = await index.getTarget('user@mail.ru', '/root');
        return target?.state == OfflineTargetState.ready;
      });

      expect(browser.calls, ['/root@0', '/root@100']);
      expect(
        await index.listTargetFiles('user@mail.ru', '/root'),
        hasLength(101),
      );
    },
  );

  test('a short page below its authoritative boundary is invalid', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-short-page');
    final index = _index(root);
    final browser = _Browser(
      (path, offset) => _page(path, [_file('/root/only.txt')], total: 2),
    );
    final queue = OfflineTargetQueueController(
      targetIndex: index,
      browserRepository: browser,
      downloadRepository: _TargetDownloads(index),
      queueStore: index,
    );
    addTearDown(() async {
      await queue.close();
      await index.close();
      await root.delete(recursive: true);
    });

    await queue.attach('user@mail.ru');
    await queue.enqueue(_folder('/root'));
    await _waitUntil(() async {
      final target = await index.getTarget('user@mail.ru', '/root');
      return target?.state == OfflineTargetState.waitingNetworkOrError;
    });

    expect(
      (await index.listFrontier('user@mail.ru', '/root')).single.nextOffset,
      0,
    );
    expect(await index.listTargetFiles('user@mail.ru', '/root'), isEmpty);
  });

  test('a child repeated on a later page is rejected as a duplicate', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-duplicate');
    final index = _index(root);
    final firstPage = List.generate(
      100,
      (number) => _file('/root/file-$number.txt'),
    );
    final browser = _Browser((path, offset) {
      if (offset == 0) return _page(path, firstPage, total: 101);
      return _page(path, [_file('/root/file-0.txt')], total: 101);
    });
    final queue = OfflineTargetQueueController(
      targetIndex: index,
      browserRepository: browser,
      downloadRepository: _TargetDownloads(index),
      queueStore: index,
    );
    addTearDown(() async {
      await queue.close();
      await index.close();
      await root.delete(recursive: true);
    });

    await queue.attach('user@mail.ru');
    await queue.enqueue(_folder('/root'));
    await _waitUntil(() async {
      final target = await index.getTarget('user@mail.ru', '/root');
      return target?.state == OfflineTargetState.waitingNetworkOrError;
    });

    expect(browser.calls, ['/root@0', '/root@100']);
    expect(
      await index.listTargetFiles('user@mail.ru', '/root'),
      hasLength(100),
    );
  });

  test('cached pages pause without persisting membership or offset', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-cache');
    final index = _index(root);
    final browser = _Browser(
      (path, offset) => _page(
        path,
        [_file('/root/cached.txt')],
        total: 1,
        source: CloudFolderPageSource.cache,
      ),
    );
    final queue = OfflineTargetQueueController(
      targetIndex: index,
      browserRepository: browser,
      downloadRepository: _TargetDownloads(index),
      queueStore: index,
    );
    addTearDown(() async {
      await queue.close();
      await index.close();
      await root.delete(recursive: true);
    });

    await queue.attach('user@mail.ru');
    await queue.enqueue(_folder('/root'));
    await _waitUntil(() async {
      final target = await index.getTarget('user@mail.ru', '/root');
      return target?.state == OfflineTargetState.waitingNetworkOrError;
    });

    final frontier = (await index.listFrontier('user@mail.ru', '/root'));
    expect(frontier.single.nextOffset, 0);
    expect(frontier.single.state, OfflineTargetFrontierState.pending);
    expect(await index.listTargetFiles('user@mail.ru', '/root'), isEmpty);
  });

  test('limits one account to two target download handles', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-limit');
    final index = _index(root);
    final browser = _Browser(
      (path, offset) => _page(
        path,
        List.generate(4, (number) => _file('/root/file-$number.txt')),
        total: 4,
      ),
    );
    final downloads = _TargetDownloads(index, blocked: true);
    final queue = OfflineTargetQueueController(
      targetIndex: index,
      browserRepository: browser,
      downloadRepository: downloads,
      queueStore: index,
    );
    addTearDown(() async {
      await queue.close();
      downloads.release();
      await index.close();
      await root.delete(recursive: true);
    });

    await queue.attach('user@mail.ru');
    await queue.enqueue(_folder('/root'));
    await _waitUntil(() async => downloads.maxActive == 2);
    expect(downloads.maxActive, 2);
    downloads.release();
    await _waitUntil(() async {
      final target = await index.getTarget('user@mail.ru', '/root');
      return target?.state == OfflineTargetState.ready;
    });
  });

  test(
    'persists the download total instead of the stale listing size',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-progress');
      final index = _index(root);
      final downloads = _TargetDownloads(
        index,
        progressTotal: 7,
        progressBytes: 7,
      );
      final queue = OfflineTargetQueueController(
        targetIndex: index,
        browserRepository: _Browser(
          (path, offset) => _page(path, [_file('/root/file.txt')], total: 1),
        ),
        downloadRepository: downloads,
        queueStore: index,
      );
      addTearDown(() async {
        await queue.close();
        await index.close();
        await root.delete(recursive: true);
      });

      await queue.attach('user@mail.ru');
      await queue.enqueue(_folder('/root'));
      await _waitUntil(() async {
        final target = await index.getTarget('user@mail.ru', '/root');
        return target?.state == OfflineTargetState.ready;
      });

      final file = await index.getTargetFile(
        'user@mail.ru',
        '/root',
        '/root/file.txt',
      );
      expect(file?.size, 7);
      expect(file?.bytesDone, 7);
    },
  );

  test(
    'repairs a ready membership without size and downloads it again',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-ready');
      final index = _index(root);
      final now = DateTime.utc(2025);
      const hash = '00112233445566778899AABBCCDDEEFF00112233';
      await index.upsertTarget(
        'user@mail.ru',
        OfflineTargetRecord(
          targetPath: '/root',
          targetIncarnation: 'test-incarnation',
          targetName: 'root',
          state: OfflineTargetState.ready,
          scanComplete: true,
          estimateHasUnknown: true,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await index.upsertFrontier(
        'user@mail.ru',
        OfflineTargetFrontierRecord(
          targetPath: '/root',
          targetIncarnation: 'test-incarnation',
          folderPath: '/root',
          nextOffset: 1,
          state: OfflineTargetFrontierState.complete,
          sequence: 0,
        ),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        OfflineTargetFileRecord(
          targetPath: '/root',
          targetIncarnation: 'test-incarnation',
          filePath: '/root/file.txt',
          name: 'file.txt',
          hash: hash,
          size: null,
          readiness: OfflineReadiness.ready,
          bytesDone: 0,
          updatedAt: now,
        ),
      );
      final downloads = _TargetDownloads(index);
      final queue = OfflineTargetQueueController(
        targetIndex: index,
        browserRepository: _Browser(
          (path, offset) => _page(path, [], total: 0),
        ),
        downloadRepository: downloads,
        queueStore: index,
      );
      addTearDown(() async {
        await queue.close();
        await index.close();
        await root.delete(recursive: true);
      });

      await queue.attach('user@mail.ru');
      await _waitUntil(() async {
        final file = await index.getTargetFile(
          'user@mail.ru',
          '/root',
          '/root/file.txt',
        );
        return file?.readiness == OfflineReadiness.ready && file?.size == 1;
      });

      expect(downloads.paths, ['/root/file.txt']);
    },
  );

  test(
    'detach recovers active target download for the next controller',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-recover');
      final index = _index(root);
      final browser = _Browser(
        (path, offset) => _page(path, [_file('/root/file.txt')], total: 1),
      );
      final downloads = _TargetDownloads(index, blocked: true);
      final queue = OfflineTargetQueueController(
        targetIndex: index,
        browserRepository: browser,
        downloadRepository: downloads,
        queueStore: index,
      );
      addTearDown(() async {
        await queue.close();
        downloads.release();
        await index.close();
        await root.delete(recursive: true);
      });

      await queue.attach('user@mail.ru');
      await queue.enqueue(_folder('/root'));
      await downloads.started.future;
      await queue.detach();

      expect(
        (await index.getTarget('user@mail.ru', '/root'))?.state,
        OfflineTargetState.queued,
      );
      expect(
        (await index.listTargetFiles('user@mail.ru', '/root')).single.readiness,
        OfflineReadiness.queued,
      );
    },
  );

  test('retry recovers a cancelled scan in the same queue process', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-retry-scan');
    final index = _index(root);
    final firstScanStarted = Completer<void>();
    final releaseFirstScan = Completer<void>();
    var calls = 0;
    final browser = _Browser((path, offset) async {
      calls++;
      if (calls == 1) {
        firstScanStarted.complete();
        await releaseFirstScan.future;
      }
      return _page(path, [_file('/root/file.txt')], total: 1);
    });
    final queue = OfflineTargetQueueController(
      targetIndex: index,
      browserRepository: browser,
      downloadRepository: _TargetDownloads(index),
      queueStore: index,
    );
    addTearDown(() async {
      if (!releaseFirstScan.isCompleted) releaseFirstScan.complete();
      await queue.close();
      await index.close();
      await root.delete(recursive: true);
    });

    await queue.attach('user@mail.ru');
    await queue.enqueue(_folder('/root'));
    await firstScanStarted.future;

    final retry = queue.retry('/root');
    releaseFirstScan.complete();
    await retry;
    await _waitUntil(() async {
      final target = await index.getTarget('user@mail.ru', '/root');
      return target?.state == OfflineTargetState.ready;
    });

    expect(calls, 2);
    expect(
      (await index.listFrontier('user@mail.ru', '/root')).single.state,
      OfflineTargetFrontierState.complete,
    );
  });

  test(
    'retry recovers a cancelled download in the same queue process',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-retry-download',
      );
      final index = _index(root);
      final downloads = _TargetDownloads(index, blocked: true);
      final queue = OfflineTargetQueueController(
        targetIndex: index,
        browserRepository: _Browser(
          (path, offset) => _page(path, [_file('/root/file.txt')], total: 1),
        ),
        downloadRepository: downloads,
        queueStore: index,
      );
      addTearDown(() async {
        downloads.release();
        await queue.close();
        await index.close();
        await root.delete(recursive: true);
      });

      await queue.attach('user@mail.ru');
      await queue.enqueue(_folder('/root'));
      await downloads.started.future;

      final retry = queue.retry('/root');
      await retry;
      await _waitUntil(() async {
        final target = await index.getTarget('user@mail.ru', '/root');
        return target?.state == OfflineTargetState.ready;
      });

      expect(downloads.paths, ['/root/file.txt', '/root/file.txt']);
    },
  );

  test('retry recovers a frontier left scanning by a commit failure', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-retry-db');
    final index = _index(root);
    final store = _FailingCommitStore(index)..failNextCommit = true;
    final browser = _Browser(
      (path, offset) => _page(path, [_file('/root/file.txt')], total: 1),
    );
    final queue = OfflineTargetQueueController(
      targetIndex: index,
      browserRepository: browser,
      downloadRepository: _TargetDownloads(index),
      queueStore: store,
    );
    addTearDown(() async {
      await queue.close();
      await index.close();
      await root.delete(recursive: true);
    });

    await queue.attach('user@mail.ru');
    await queue.enqueue(_folder('/root'));
    await _waitUntil(() async {
      final target = await index.getTarget('user@mail.ru', '/root');
      return target?.state == OfflineTargetState.waitingNetworkOrError;
    });
    expect(
      (await index.listFrontier('user@mail.ru', '/root')).single.state,
      OfflineTargetFrontierState.scanning,
    );

    await queue.retry('/root');
    await _waitUntil(() async {
      final target = await index.getTarget('user@mail.ru', '/root');
      return target?.state == OfflineTargetState.ready;
    });

    expect(store.commitCalls, 2);
    expect(browser.calls, ['/root@0', '/root@0']);
  });

  test(
    'removing during traversal prevents stale ownership recreation',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-remove');
      final index = _index(root);
      final pageStarted = Completer<void>();
      final releasePage = Completer<void>();
      final browser = _Browser((path, offset) async {
        if (!pageStarted.isCompleted) pageStarted.complete();
        await releasePage.future;
        return _page(path, [_file('/root/file.txt')], total: 1);
      });
      final downloads = _TargetDownloads(index);
      final queue = OfflineTargetQueueController(
        targetIndex: index,
        browserRepository: browser,
        downloadRepository: downloads,
        queueStore: index,
      );
      addTearDown(() async {
        if (!releasePage.isCompleted) releasePage.complete();
        await queue.close();
        await index.close();
        await root.delete(recursive: true);
      });

      await queue.attach('user@mail.ru');
      await queue.enqueue(_folder('/root'));
      await pageStarted.future;
      final removal = queue.remove('/root');
      releasePage.complete();
      await removal;

      expect(await index.getTarget('user@mail.ru', '/root'), isNull);
      expect(await index.listTargetFiles('user@mail.ru', '/root'), isEmpty);
      expect(downloads.paths, isEmpty);
    },
  );

  test(
    'account epoch changes stop traversal before durable page commit',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-epoch');
      final index = _index(root);
      final provider = _EpochProvider('user@mail.ru', 1);
      final pageStarted = Completer<void>();
      final releasePage = Completer<void>();
      final browser = _Browser((path, offset) async {
        pageStarted.complete();
        await releasePage.future;
        return _page(path, [_file('/root/file.txt')], total: 1);
      });
      final queue = OfflineTargetQueueController(
        targetIndex: index,
        browserRepository: browser,
        downloadRepository: _TargetDownloads(index),
        queueStore: index,
        accountEpochProvider: provider,
      );
      addTearDown(() async {
        if (!releasePage.isCompleted) releasePage.complete();
        await queue.close();
        await index.close();
        await root.delete(recursive: true);
      });

      await queue.attach('user@mail.ru');
      await queue.enqueue(_folder('/root'));
      await pageStarted.future;
      provider.currentEmail = 'other@mail.ru';
      provider.epoch = 2;
      releasePage.complete();
      await queue.detach();

      expect(await index.listTargetFiles('user@mail.ru', '/root'), isEmpty);
      expect(
        (await index.listFrontier('user@mail.ru', '/root')).single.nextOffset,
        0,
      );
      expect(
        (await index.getTarget('user@mail.ru', '/root'))?.state,
        OfflineTargetState.queued,
      );
    },
  );

  test('reattach adopts a changed epoch for the same account', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-reattach');
    final index = _index(root);
    final provider = _EpochProvider('user@mail.ru', 1);
    final queue = OfflineTargetQueueController(
      targetIndex: index,
      browserRepository: _Browser((path, offset) => _page(path, [], total: 0)),
      downloadRepository: _TargetDownloads(index),
      queueStore: index,
      accountEpochProvider: provider,
    );
    addTearDown(() async {
      await queue.close();
      await index.close();
      await root.delete(recursive: true);
    });

    await queue.attach('user@mail.ru');
    expect(queue.accountEpoch, 1);

    provider.epoch = 2;
    await queue.attach('USER@MAIL.RU');

    expect(queue.email, 'user@mail.ru');
    expect(queue.accountEpoch, 2);
  });
}

SqliteOfflineFileIndex _index(Directory root) => SqliteOfflineFileIndex(
  rootProvider: FixedCacheRoot(root),
  databaseFactory: databaseFactoryFfi,
);

CloudFolderPage _page(
  String folder,
  List<CloudNode> items, {
  required int total,
  CloudFolderPageSource source = CloudFolderPageSource.remote,
}) => CloudFolderPage(
  folder: _folder(folder),
  items: items,
  totalCount: total,
  sort: CloudSort.nameAscending,
  source: source,
);

CloudNode _folder(String path) => CloudNode(
  path: path,
  name: path == '/' ? 'root' : path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.folder,
);

CloudNode _file(String path) => CloudNode(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.file,
  size: 1,
);

Future<void> _waitUntil(Future<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for the offline target worker.');
}

final class _FailingCommitStore implements OfflineTargetQueueStore {
  _FailingCommitStore(this._delegate);

  final SqliteOfflineFileIndex _delegate;
  bool failNextCommit = false;
  int commitCalls = 0;

  @override
  Future<void> createTargetWithRootIfNoOverlap(
    String email,
    OfflineTargetRecord target,
    OfflineTargetFrontierRecord root,
  ) => _delegate.createTargetWithRootIfNoOverlap(email, target, root);

  @override
  Future<void> updateTarget(String email, OfflineTargetRecord target) =>
      _delegate.updateTarget(email, target);

  @override
  Future<void> commitFrontierPage(
    String email, {
    required OfflineTargetFrontierRecord current,
    required OfflineTargetFrontierRecord updated,
    required Iterable<OfflineTargetFrontierRecord> discoveredFolders,
    required Iterable<OfflineTargetFileRecord> discoveredFiles,
  }) {
    commitCalls++;
    if (failNextCommit) {
      failNextCommit = false;
      throw StateError('simulated persistence failure');
    }
    return _delegate.commitFrontierPage(
      email,
      current: current,
      updated: updated,
      discoveredFolders: discoveredFolders,
      discoveredFiles: discoveredFiles,
    );
  }
}

final class _Browser implements BrowserRepository {
  _Browser(this._pages);

  final FutureOr<CloudFolderPage> Function(String path, int offset) _pages;
  final calls = <String>[];

  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async {
    expect(limit, 100);
    expect(sort, CloudSort.nameAscending);
    calls.add('$path@$offset');
    return await _pages(path, offset);
  }

  @override
  Future<void> close() async {}
}

final class _EpochProvider implements AccountEpochProvider {
  _EpochProvider(this.currentEmail, this.epoch);

  @override
  String? currentEmail;

  @override
  int epoch;
}

final class _TargetDownloads implements DownloadRepository {
  _TargetDownloads(
    this.index, {
    this.blocked = false,
    this.progressTotal,
    this.progressBytes,
  });

  final OfflineTargetIndex index;
  final bool blocked;
  final int? progressTotal;
  final int? progressBytes;
  final started = Completer<void>();
  final paths = <String>[];
  final _release = Completer<void>();
  int active = 0;
  int maxActive = 0;

  @override
  DownloadHandle start(CloudNode node) => throw UnimplementedError();

  @override
  DownloadHandle startOpen(CloudNode node) => throw UnimplementedError();

  @override
  DownloadHandle startTarget(
    CloudNode node, {
    required String targetPath,
    required String expectedEmail,
    required String targetIncarnation,
  }) {
    paths.add(node.path);
    late final _FakeHandle handle;
    handle = _FakeHandle(
      () async {
        if (!started.isCompleted) started.complete();
        active++;
        if (active > maxActive) maxActive = active;
        try {
          if (blocked) await _release.future;
          if (handle.cancelled) throw const DownloadCancelled();
          await index.markTargetFileReady(
            expectedEmail,
            targetPath: targetPath,
            filePath: node.path,
            targetIncarnation: targetIncarnation,
            hash: '00112233445566778899AABBCCDDEEFF00112233',
            size: node.size ?? 1,
          );
          return File('fake-target-file');
        } finally {
          active--;
        }
      },
      onCancel: release,
      committedTotal: progressTotal ?? 1,
      committedBytes: progressBytes ?? 1,
    );
    return handle;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<void> removeOffline(CloudNode node) async {}

  @override
  Future<void> removeTarget(
    String targetPath, {
    required String expectedEmail,
    required String targetIncarnation,
  }) async {
    await index.removeTarget(
      expectedEmail,
      targetPath,
      targetIncarnation: targetIncarnation,
    );
  }

  @override
  Future<void> reconcileAccountCache({required String expectedEmail}) async {}

  @override
  Future<void> close() async {}
}

final class _FakeHandle implements DownloadHandle {
  _FakeHandle(
    Future<File> Function() run, {
    void Function()? onCancel,
    this.committedTotal = 1,
    this.committedBytes = 1,
  }) : _onCancel = onCancel {
    result = Future<File>.microtask(() async {
      try {
        final file = await run();
        if (!_progress.isClosed) {
          _progress.add(
            DownloadProgress(
              phase: DownloadPhase.committed,
              bytes: committedBytes,
              total: committedTotal,
              resumed: false,
            ),
          );
          await _progress.close();
        }
        return file;
      } catch (error, stackTrace) {
        if (!_progress.isClosed) await _progress.close();
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
  }

  final _progress = StreamController<DownloadProgress>.broadcast(sync: true);
  final void Function()? _onCancel;
  final int committedTotal;
  final int committedBytes;
  @override
  late final Future<File> result;
  bool cancelled = false;

  @override
  Stream<DownloadProgress> get progress => _progress.stream;

  @override
  void cancel() {
    cancelled = true;
    _onCancel?.call();
  }
}
