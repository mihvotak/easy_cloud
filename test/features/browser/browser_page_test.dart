import 'dart:async';
import 'dart:io';

import 'package:easy_cloud/core/errors/cloud_failure.dart';
import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:easy_cloud/features/auth/presentation/auth_controller.dart';
import 'package:easy_cloud/features/browser/application/browser_repository.dart';
import 'package:easy_cloud/features/browser/domain/cloud_folder_page.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:easy_cloud/features/browser/presentation/browser_page.dart';
import 'package:easy_cloud/features/browser/presentation/cloud_connection_controller.dart';
import 'package:easy_cloud/features/download/application/download_repository.dart';
import 'package:easy_cloud/features/download/domain/download_handle.dart';
import 'package:easy_cloud/features/download/domain/download_progress.dart';
import 'package:easy_cloud/features/download/presentation/download_controller.dart';
import 'package:easy_cloud/features/offline/application/offline_file_index.dart';
import 'package:easy_cloud/features/open/application/file_opener.dart';
import 'package:easy_cloud/features/open/application/open_file_controller.dart';
import 'package:easy_cloud/features/open/domain/open_file_failure.dart';
import 'package:easy_cloud/features/search/application/search_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'shows cached content with a bottom connection panel and retries',
    (tester) async {
      final auth = AuthController(
        AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
      );
      final downloads = DownloadController(_NoopDownloadRepository());
      final failure = const CloudFailure(CloudFailureType.network, 'offline');
      final repository = _QueueBrowserRepository([
        _browserPage(
          '/cached.txt',
          source: CloudFolderPageSource.cache,
          connectionFailure: failure,
        ),
        _browserPage('/remote.txt'),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: BrowserPage(
            repository: repository,
            searchRepository: _NoopSearchRepository(),
            downloadController: downloads,
            openFileController: _openFileController(),
            offlineFileIndex: _NoopOfflineFileIndex(),
            authController: auth,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('cached.txt'), findsOneWidget);
      expect(find.text('Нет соединения'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Повторить'), findsOneWidget);
      expect(find.text('Не удалось открыть папку'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Повторить'));
      await tester.pumpAndSettle();

      expect(find.text('remote.txt'), findsOneWidget);
      expect(find.text('Нет соединения'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      auth.dispose();
    },
  );

  testWidgets(
    'keeps the full-screen error when initial navigation has no cache',
    (tester) async {
      final auth = AuthController(
        AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
      );
      final downloads = DownloadController(_NoopDownloadRepository());
      final repository = _QueueBrowserRepository([
        const CloudFailure(CloudFailureType.network, 'offline'),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: BrowserPage(
            repository: repository,
            searchRepository: _NoopSearchRepository(),
            downloadController: downloads,
            openFileController: _openFileController(),
            offlineFileIndex: _NoopOfflineFileIndex(),
            authController: auth,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Не удалось открыть папку'), findsOneWidget);
      expect(find.text('Нет соединения'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      auth.dispose();
    },
  );

  testWidgets('opens a folder and returns to the parent', (tester) async {
    final repository = _TreeRepository();
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloads = DownloadController(_NoopDownloadRepository());
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: repository,
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: _openFileController(),
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Documents'), findsOneWidget);
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();

    expect(find.text('readme.md'), findsOneWidget);
    expect(find.text('Documents'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('photo.jpg'), findsOneWidget);
    auth.dispose();
    downloads.dispose();
  });

  testWidgets('keeps a child connectivity failure visible after returning', (
    tester,
  ) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloads = DownloadController(_NoopDownloadRepository());
    final connection = CloudConnectionController();
    final repository = _ChildFailureRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: repository,
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: _openFileController(),
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
          connectionController: connection,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(connection.isOffline, isTrue);
    expect(find.text('Не удалось открыть папку'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Нет соединения'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    connection.dispose();
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('refreshes after a remote foreground open while offline', (
    tester,
  ) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloadRepository = _ControllableDownloadRepository();
    final downloads = DownloadController(downloadRepository);
    final opens = _openFileController(downloadRepository, _NoopFileOpener());
    final connection = CloudConnectionController();
    final failure = const CloudFailure(CloudFailureType.network, 'offline');
    final repository = _QueueBrowserRepository([
      _browserPage(
        '/cached.txt',
        source: CloudFolderPageSource.cache,
        connectionFailure: failure,
      ),
      _browserPage('/remote.txt'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: repository,
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: opens,
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
          connectionController: connection,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Нет соединения'), findsOneWidget);

    await tester.tap(find.text('cached.txt'));
    await tester.pump();
    downloadRepository.progress.add(
      const DownloadProgress(
        phase: DownloadPhase.receiving,
        bytes: 1,
        total: 1,
        resumed: false,
        cacheHit: false,
      ),
    );
    downloadRepository.result.complete(File('/cache/cached.txt'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pumpAndSettle();

    expect(opens.lastSuccessfulCacheHit, isFalse);
    expect(repository.calls, 2);
    expect(find.text('remote.txt'), findsOneWidget);
    expect(find.text('Нет соединения'), findsNothing);
    expect(connection.isOffline, isFalse);

    await tester.pumpWidget(const SizedBox());
    opens.dispose();
    connection.dispose();
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('cache-hit foreground success does not prove connectivity', (
    tester,
  ) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloadRepository = _ControllableDownloadRepository();
    final downloads = DownloadController(downloadRepository);
    final opens = _openFileController(downloadRepository, _NoopFileOpener());
    final connection = CloudConnectionController();
    final failure = const CloudFailure(CloudFailureType.network, 'offline');
    final repository = _QueueBrowserRepository([
      _browserPage(
        '/cached.txt',
        source: CloudFolderPageSource.cache,
        connectionFailure: failure,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: repository,
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: opens,
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
          connectionController: connection,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('cached.txt'));
    await tester.pump();
    downloadRepository.progress.add(
      const DownloadProgress(
        phase: DownloadPhase.committed,
        bytes: 1,
        total: 1,
        resumed: false,
        cacheHit: true,
      ),
    );
    downloadRepository.result.complete(File('/cache/cached.txt'));
    await tester.pumpAndSettle();

    expect(repository.calls, 1);
    expect(find.text('Нет соединения'), findsOneWidget);
    expect(connection.isOffline, isTrue);

    await tester.pumpWidget(const SizedBox());
    opens.dispose();
    connection.dispose();
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('failed foreground open probes the current folder', (
    tester,
  ) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloadRepository = _ControllableDownloadRepository();
    final downloads = DownloadController(downloadRepository);
    final opens = _openFileController(downloadRepository, _NoopFileOpener());
    final connection = CloudConnectionController();
    final repository = _QueueBrowserRepository([
      _browserPage('/remote.txt'),
      const CloudFailure(CloudFailureType.network, 'offline'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: repository,
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: opens,
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
          connectionController: connection,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('remote.txt'));
    await tester.pump();
    downloadRepository.result.completeError(StateError('private failure'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pumpAndSettle();

    expect(connection.isOffline, isTrue);
    expect(find.text('Нет соединения'), findsOneWidget);
    expect(find.text(OpenFileFailure.safeMessage), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    opens.dispose();
    connection.dispose();
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('opens a file through the foreground controller', (tester) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloadRepository = _ControllableDownloadRepository();
    final opener = _RecordingFileOpener();
    final opens = _openFileController(downloadRepository, opener);
    final downloads = DownloadController(downloadRepository);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: _TreeRepository(),
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: opens,
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('photo.jpg'));
    await tester.pump();
    expect(downloadRepository.openStarts, 1);
    expect(downloadRepository.starts, 0);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    downloadRepository.progress.add(
      const DownloadProgress(
        phase: DownloadPhase.receiving,
        bytes: 512,
        total: 1024,
        resumed: false,
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .5,
    );

    downloadRepository.result.complete(File('/cache/object'));
    await tester.pumpAndSettle();
    expect(opener.paths, [File('/cache/object').absolute.path]);
    expect(downloads.stateFor('/photo.jpg'), isNull);

    await tester.pumpWidget(const SizedBox());
    opens.dispose();
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('saves a file from the context menu through startOpen', (
    tester,
  ) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloadRepository = _ControllableDownloadRepository();
    final exporter = _RecordingFileExporter();
    final opens = _openFileController(
      downloadRepository,
      _NoopFileOpener(),
      exporter,
    );
    final downloads = DownloadController(downloadRepository);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: _TreeRepository(),
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: opens,
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия для photo.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('Сохранить как'), findsOneWidget);
    await tester.tap(find.text('Сохранить как'));
    await tester.pump();
    expect(downloadRepository.openStarts, 1);
    expect(downloadRepository.starts, 0);

    downloadRepository.result.complete(File('/cache/photo.jpg'));
    await tester.pumpAndSettle();
    expect(exporter.paths, [File('/cache/photo.jpg').absolute.path]);
    expect(exporter.displayNames, ['photo.jpg']);

    await tester.pumpWidget(const SizedBox());
    opens.dispose();
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('downloads a file from metadata and shows progress', (
    tester,
  ) async {
    final repository = _TreeRepository();
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloadRepository = _ControllableDownloadRepository();
    final downloads = DownloadController(downloadRepository);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: repository,
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: _openFileController(downloadRepository),
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия для photo.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Инфо'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Скачать для офлайн-доступа'));
    await tester.pump();
    expect(downloadRepository.starts, 1);

    downloadRepository.progress.add(
      const DownloadProgress(
        phase: DownloadPhase.receiving,
        bytes: 512,
        total: 1024,
        resumed: false,
      ),
    );
    await tester.pump();
    expect(find.text('512 Б из 1.0 КБ'), findsOneWidget);

    downloadRepository.result.complete(File('cached-photo'));
    await tester.pumpAndSettle();
    expect(downloads.stateFor('/photo.jpg')?.status, DownloadItemStatus.ready);
    expect(
      find.text('Файл доступен офлайн', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Доступен офлайн', skipOffstage: false),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('starts a file download from its context menu', (tester) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloadRepository = _ControllableDownloadRepository();
    final downloads = DownloadController(downloadRepository);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: _TreeRepository(),
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: _openFileController(downloadRepository),
          offlineFileIndex: _NoopOfflineFileIndex(),
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия для photo.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('Работать оффлайн'), findsOneWidget);
    await tester.tap(find.text('Работать оффлайн'));
    await tester.pump();

    expect(downloadRepository.starts, 1);
    expect(find.text('photo.jpg'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('removes direct offline availability and refreshes the index', (
    tester,
  ) async {
    final auth = _signedInAuth();
    final offline = _LookupOfflineFileIndex({
      '/photo.jpg': _record('/photo.jpg'),
    });
    final downloadRepository = _ControllableDownloadRepository()
      ..onRemove = (node) async {
        offline.records.remove(node.path);
      };
    final downloads = DownloadController(downloadRepository);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: _TreeRepository(),
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: _openFileController(downloadRepository),
          offlineFileIndex: offline,
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Доступен офлайн'), findsOneWidget);
    await tester.tap(find.byTooltip('Действия для photo.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('Только онлайн'), findsOneWidget);
    await tester.tap(find.text('Только онлайн'));
    await tester.pumpAndSettle();

    expect(downloadRepository.removeCalls, 1);
    expect(offline.lookupPaths, hasLength(2));
    expect(find.byTooltip('Доступен офлайн'), findsNothing);
    expect(find.byTooltip('Только онлайн'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('shows a safe error when removing offline availability fails', (
    tester,
  ) async {
    final auth = _signedInAuth();
    final offline = _LookupOfflineFileIndex({
      '/photo.jpg': _record('/photo.jpg'),
    });
    final downloadRepository = _ControllableDownloadRepository()
      ..removeFailure = StateError('private filesystem path');
    final downloads = DownloadController(downloadRepository);
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: _TreeRepository(),
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: _openFileController(downloadRepository),
          offlineFileIndex: offline,
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Действия для photo.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Только онлайн'));
    await tester.pumpAndSettle();

    expect(downloadRepository.removeCalls, 1);
    expect(find.text('Не удалось отключить офлайн-доступ.'), findsOneWidget);
    expect(find.text('private filesystem path'), findsNothing);
    expect(find.byTooltip('Доступен офлайн'), findsOneWidget);
    expect(offline.lookupPaths, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('loads persisted availability for visible files', (tester) async {
    final auth = _signedInAuth();
    final downloads = DownloadController(_NoopDownloadRepository());
    final offline = _LookupOfflineFileIndex({
      '/photo.jpg': _record('/photo.jpg'),
    });

    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: _TreeRepository(),
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: _openFileController(),
          offlineFileIndex: offline,
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(offline.lookupEmails, ['reader@mail.ru']);
    expect(offline.lookupPaths, [
      <String>{'/photo.jpg'},
    ]);
    expect(find.byTooltip('Доступен офлайн'), findsOneWidget);
    expect(find.byTooltip('Только онлайн'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('does not look up availability without a session', (
    tester,
  ) async {
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
    );
    final downloads = DownloadController(_NoopDownloadRepository());
    final offline = _LookupOfflineFileIndex({
      '/photo.jpg': _record('/photo.jpg'),
    });

    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: _TreeRepository(),
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: _openFileController(),
          offlineFileIndex: offline,
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(offline.lookupEmails, isEmpty);
    expect(find.byTooltip('Только онлайн'), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });

  testWidgets('opens the offline files for the signed-in account', (
    tester,
  ) async {
    final store = MemorySessionStore()
      ..session = CloudSession(
        email: 'reader@mail.ru',
        accessToken: 'access',
        refreshToken: 'refresh',
        csrfToken: 'csrf',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
    final auth = AuthController(
      AuthRepository(api: _NoopAuthApi(), store: store),
    );
    await auth.initialize();
    final downloads = DownloadController(_NoopDownloadRepository());
    final offline = _NoopOfflineFileIndex();
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          repository: _TreeRepository(),
          searchRepository: _NoopSearchRepository(),
          downloadController: downloads,
          openFileController: _openFileController(),
          offlineFileIndex: offline,
          authController: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Офлайн-файлы'));
    await tester.pumpAndSettle();

    expect(find.text('Офлайн-файлы'), findsOneWidget);
    expect(find.text('Нет офлайн-файлов'), findsOneWidget);
    expect(offline.listedEmails, ['reader@mail.ru']);

    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    auth.dispose();
  });
}

OpenFileController _openFileController([
  DownloadRepository? repository,
  FileOpener? fileOpener,
  FileExporter? fileExporter,
]) => OpenFileController(
  repository ?? _NoopDownloadRepository(),
  fileOpener ?? _NoopFileOpener(),
  fileExporter,
);

final class _NoopFileOpener implements FileOpener {
  @override
  Future<void> openFile(String absolutePath, String displayName) async {}
}

final class _RecordingFileOpener implements FileOpener {
  final paths = <String>[];
  final displayNames = <String>[];

  @override
  Future<void> openFile(String absolutePath, String displayName) async {
    paths.add(absolutePath);
    displayNames.add(displayName);
  }
}

final class _RecordingFileExporter implements FileExporter {
  final paths = <String>[];
  final displayNames = <String>[];

  @override
  Future<bool> saveFileAs(String absolutePath, String displayName) async {
    paths.add(absolutePath);
    displayNames.add(displayName);
    return true;
  }
}

final class _NoopDownloadRepository implements DownloadRepository {
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
  }) => throw UnimplementedError();

  @override
  Future<void> removeOffline(CloudNode node) async {}

  @override
  Future<void> removeTarget(
    String targetPath, {
    required String expectedEmail,
    required String targetIncarnation,
  }) async {}

  @override
  Future<void> reconcileAccountCache({required String expectedEmail}) async {}

  @override
  Future<void> close() async {}
}

final class _NoopOfflineFileIndex implements OfflineFileIndex {
  final listedEmails = <String>[];

  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {}

  @override
  Future<List<OfflineFileRecord>> list(String email) async {
    listedEmails.add(email);
    return const [];
  }

  @override
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  ) async => const {};

  @override
  Future<bool> hasHashReference(String email, String hash) async => false;

  @override
  Future<void> remove(String email, String path) async {}

  @override
  Future<void> clearAccount(String email) async {}

  @override
  Future<void> close() async {}
}

final class _LookupOfflineFileIndex implements OfflineFileIndex {
  _LookupOfflineFileIndex(this.records);

  final Map<String, OfflineFileRecord> records;
  final lookupEmails = <String>[];
  final lookupPaths = <Set<String>>[];

  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {}

  @override
  Future<List<OfflineFileRecord>> list(String email) async => const [];

  @override
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  ) async {
    final requested = paths.toSet();
    lookupEmails.add(email);
    lookupPaths.add(requested);
    final found = <String, OfflineFileRecord>{};
    for (final path in requested) {
      final record = records[path];
      if (record != null) found[path] = record;
    }
    return found;
  }

  @override
  Future<bool> hasHashReference(String email, String hash) async =>
      records.values.any((record) => record.hash == hash.trim().toUpperCase());

  @override
  Future<void> remove(String email, String path) async {}

  @override
  Future<void> clearAccount(String email) async {}

  @override
  Future<void> close() async {}
}

AuthController _signedInAuth() {
  final auth = AuthController(
    AuthRepository(api: _NoopAuthApi(), store: MemorySessionStore()),
  );
  auth.session = CloudSession(
    email: 'reader@mail.ru',
    accessToken: 'access',
    refreshToken: 'refresh',
    csrfToken: 'csrf',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
  auth.status = AuthStatus.signedIn;
  return auth;
}

OfflineFileRecord _record(String path) => OfflineFileRecord(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  hash: '00112233445566778899AABBCCDDEEFF00112233',
  size: 1,
  cachedAt: DateTime.utc(2025, 1, 1),
);

final class _ControllableDownloadRepository implements DownloadRepository {
  final progress = StreamController<DownloadProgress>.broadcast();
  final result = Completer<File>();
  int starts = 0;
  int openStarts = 0;
  int removeCalls = 0;
  Object? removeFailure;
  Future<void> Function(CloudNode node)? onRemove;

  @override
  DownloadHandle start(CloudNode node) {
    starts++;
    return _ControllableDownloadHandle(progress.stream, result.future);
  }

  @override
  DownloadHandle startOpen(CloudNode node) {
    openStarts++;
    return _ControllableDownloadHandle(progress.stream, result.future);
  }

  @override
  DownloadHandle startTarget(
    CloudNode node, {
    required String targetPath,
    required String expectedEmail,
    required String targetIncarnation,
  }) => _ControllableDownloadHandle(progress.stream, result.future);

  @override
  Future<void> removeOffline(CloudNode node) async {
    removeCalls++;
    if (removeFailure case final failure?) throw failure;
    final callback = onRemove;
    if (callback != null) await callback(node);
  }

  @override
  Future<void> removeTarget(
    String targetPath, {
    required String expectedEmail,
    required String targetIncarnation,
  }) async {}

  @override
  Future<void> reconcileAccountCache({required String expectedEmail}) async {}

  @override
  Future<void> close() async {
    await progress.close();
  }
}

final class _ControllableDownloadHandle implements DownloadHandle {
  const _ControllableDownloadHandle(this.progress, this.result);

  @override
  final Stream<DownloadProgress> progress;

  @override
  final Future<File> result;

  @override
  void cancel() {}
}

final class _NoopSearchRepository implements SearchRepository {
  @override
  Future<List<CloudNode>> search(
    String query, {
    String path = '/',
    int limit = 100,
  }) async => const [];
}

final class _TreeRepository implements BrowserRepository {
  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async {
    final isRoot = path == '/';
    return CloudFolderPage(
      folder: CloudNode(
        path: path,
        name: isRoot ? 'Облако' : 'Documents',
        type: CloudNodeType.folder,
      ),
      items: isRoot
          ? const [
              CloudNode(
                path: '/Documents',
                name: 'Documents',
                type: CloudNodeType.folder,
              ),
              CloudNode(
                path: '/photo.jpg',
                name: 'photo.jpg',
                type: CloudNodeType.file,
              ),
            ]
          : const [
              CloudNode(
                path: '/Documents/readme.md',
                name: 'readme.md',
                type: CloudNodeType.file,
              ),
            ],
      totalCount: isRoot ? 2 : 1,
      sort: sort,
    );
  }

  @override
  void close() {}
}

final class _ChildFailureRepository implements BrowserRepository {
  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async {
    if (path != '/') {
      throw const CloudFailure(CloudFailureType.network, 'offline');
    }
    return CloudFolderPage(
      folder: const CloudNode(
        path: '/',
        name: 'Облако',
        type: CloudNodeType.folder,
      ),
      items: const [
        CloudNode(
          path: '/Documents',
          name: 'Documents',
          type: CloudNodeType.folder,
        ),
      ],
      totalCount: 1,
      sort: sort,
    );
  }

  @override
  void close() {}
}

final class _QueueBrowserRepository implements BrowserRepository {
  _QueueBrowserRepository(this.results);

  final List<Object> results;
  var calls = 0;

  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async {
    calls++;
    final result = results.removeAt(0);
    if (result is CloudFailure) throw result;
    return result as CloudFolderPage;
  }

  @override
  void close() {}
}

CloudFolderPage _browserPage(
  String itemPath, {
  CloudFolderPageSource source = CloudFolderPageSource.remote,
  CloudFailure? connectionFailure,
}) => CloudFolderPage(
  folder: const CloudNode(path: '/', name: 'Cloud', type: CloudNodeType.folder),
  items: [
    CloudNode(
      path: itemPath,
      name: itemPath.substring(1),
      type: CloudNodeType.file,
    ),
  ],
  totalCount: 1,
  sort: CloudSort.nameAscending,
  source: source,
  connectionFailure: connectionFailure,
);

final class _NoopAuthApi implements AuthApi {
  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<CloudSession> refresh(CloudSession session) =>
      throw UnimplementedError();

  @override
  void close() {}
}
