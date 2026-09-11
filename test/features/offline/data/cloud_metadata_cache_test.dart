import 'dart:async';
import 'dart:io';

import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:easy_cloud/features/browser/application/browser_repository.dart';
import 'package:easy_cloud/features/browser/data/cached_browser_repository.dart';
import 'package:easy_cloud/features/browser/domain/cloud_folder_page.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:easy_cloud/features/offline/data/sqlite_offline_file_index.dart';
import 'package:easy_cloud/local/cache/application_cache_root.dart';
import 'package:easy_cloud/local/cache/content_addressed_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'stores complete node metadata and sorts locally with pagination',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
      final cache = _cache(root);
      addTearDown(() async {
        await cache.close();
        await root.delete(recursive: true);
      });
      final fetchedAt = DateTime.utc(2026, 1, 2, 3, 4, 5, 6);
      final folder = _folder(
        kind: 'folder-kind',
        revision: 'folder-rev',
        globalRevision: 'folder-global-rev',
        tree: 'tree',
        webLink: 'https://example.test/folder',
        virusScan: 'clean',
        fileCount: 2,
        folderCount: 1,
      );
      final first = _node(
        '/b.txt',
        name: 'same',
        size: 20,
        modifiedAt: DateTime.utc(2025, 2, 1),
        kind: 'text',
        hash: 'hash-b',
        revision: 'b-rev',
        globalRevision: 'b-global-rev',
        tree: 'b-tree',
        webLink: 'https://example.test/b',
        virusScan: 'clean',
        fileCount: 3,
        folderCount: 4,
      );
      final second = _node(
        '/a.txt',
        name: 'same',
        size: 10,
        modifiedAt: DateTime.utc(2025, 1, 1),
      );

      await cache.storePage(
        'reader@mail.ru',
        CloudFolderPage(
          folder: folder,
          items: [first, second],
          totalCount: 2,
          sort: CloudSort.nameAscending,
        ),
        offset: 0,
        limit: 100,
        fetchedAt: fetchedAt,
      );

      final result = await cache.readFolder(
        'READER@MAIL.RU',
        '/',
        sort: const CloudSort(CloudSortField.size, CloudSortOrder.descending),
        offset: 0,
        limit: 1,
      );
      expect(result, isNotNull);
      expect(result!.complete, isTrue);
      expect(result.fetchedAt, fetchedAt);
      expect(result.page.sort.field, CloudSortField.size);
      expect(result.page.totalCount, 2);
      expect(result.page.items.single.path, '/b.txt');
      expect(result.page.items.single.kind, 'text');
      expect(result.page.items.single.hash, 'hash-b');
      expect(result.page.items.single.modifiedAt, DateTime.utc(2025, 2, 1));
      expect(result.page.items.single.revision, 'b-rev');
      expect(result.page.items.single.globalRevision, 'b-global-rev');
      expect(result.page.items.single.tree, 'b-tree');
      expect(result.page.items.single.webLink, 'https://example.test/b');
      expect(result.page.items.single.virusScan, 'clean');
      expect(result.page.items.single.fileCount, 3);
      expect(result.page.items.single.folderCount, 4);
      expect(result.page.folder.kind, 'folder-kind');
      expect(result.page.folder.fileCount, 2);
      expect(result.page.folder.folderCount, 1);

      final secondPage = await cache.readFolder(
        'reader@mail.ru',
        '/',
        sort: const CloudSort(CloudSortField.size, CloudSortOrder.descending),
        offset: 1,
        limit: 1,
      );
      expect(secondPage!.page.items.single.path, '/a.txt');
    },
  );

  test('keeps the published generation while refresh is incomplete', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
    final cache = _cache(root);
    addTearDown(() async {
      await cache.close();
      await root.delete(recursive: true);
    });

    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/old.txt')], total: 1),
      offset: 0,
      limit: 100,
      fetchedAt: _time(1),
    );
    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/new-1.txt')], total: 2),
      offset: 0,
      limit: 1,
      fetchedAt: _time(2),
    );

    final published = await cache.readFolder('reader@mail.ru', '/');
    expect(published!.complete, isTrue);
    expect(published.page.items.map((item) => item.path), ['/old.txt']);

    final otherAccount = await cache.readFolder('other@mail.ru', '/');
    expect(otherAccount, isNull);

    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/new-2.txt')], total: 2),
      offset: 1,
      limit: 1,
      fetchedAt: _time(3),
    );
    final refreshed = await cache.readFolder('reader@mail.ru', '/');
    expect(refreshed!.complete, isTrue);
    expect(refreshed.fetchedAt, _time(3));
    expect(refreshed.page.items.map((item) => item.path), [
      '/new-1.txt',
      '/new-2.txt',
    ]);
  });

  test(
    'keeps the newest SQLite generation when folder responses overlap',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
      final cache = _cache(root);
      final auth = AuthRepository(
        api: _MetadataAuthApi(),
        store: MemorySessionStore()..session = _metadataSession(),
      );
      await auth.restore();
      final oldPage = Completer<CloudFolderPage>();
      final newPage = Completer<CloudFolderPage>();
      final remote = _MetadataRaceBrowser((call) {
        return call == 1 ? oldPage.future : newPage.future;
      });
      final repository = CachedBrowserRepository(
        remote: remote,
        cache: cache,
        authRepository: auth,
      );
      addTearDown(() async {
        repository.close();
        auth.close();
        await cache.close();
        await root.delete(recursive: true);
      });

      final staleRequest = repository.listFolder('/');
      await Future<void>.delayed(Duration.zero);
      final currentRequest = repository.listFolder(
        '/',
        sort: const CloudSort(CloudSortField.name, CloudSortOrder.descending),
      );
      await Future<void>.delayed(Duration.zero);

      final currentPage = _page([_node('/new.txt')], total: 1);
      newPage.complete(currentPage);
      expect(await currentRequest, same(currentPage));
      final stalePage = _page([_node('/old.txt')], total: 1);
      oldPage.complete(stalePage);
      expect(await staleRequest, same(stalePage));

      final cached = await cache.readFolder(
        'reader@mail.ru',
        '/',
        sort: const CloudSort(CloudSortField.name, CloudSortOrder.descending),
      );
      expect(cached?.page.items.single.path, '/new.txt');
      expect(cached?.page.sort.order, CloudSortOrder.descending);
    },
  );

  test('does not retain abandoned incomplete generations', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
    final cache = _cache(root);
    addTearDown(() async {
      await cache.close();
      await root.delete(recursive: true);
    });

    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/published.txt')], total: 1),
      offset: 0,
      limit: 100,
      fetchedAt: _time(1),
    );
    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/abandoned.txt')], total: 2),
      offset: 0,
      limit: 1,
      fetchedAt: _time(2),
    );
    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/current.txt')], total: 2),
      offset: 0,
      limit: 1,
      fetchedAt: _time(3),
    );

    final visible = await cache.readFolder('reader@mail.ru', '/');
    expect(visible!.page.items.map((item) => item.path), ['/published.txt']);

    await cache.close();
    final database = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'cloud_cache', SqliteOfflineFileIndex.databaseFileName),
    );
    addTearDown(database.close);
    final key = accountCacheKey('reader@mail.ru');
    final generations = await database.rawQuery(
      'SELECT generation_id FROM '
      '${SqliteOfflineFileIndex.snapshotGenerationsTableName} '
      'WHERE account_key = ? AND folder_path = ?',
      [key, '/'],
    );
    expect(generations, hasLength(2));
    final children = await database.rawQuery(
      'SELECT child_path FROM '
      '${SqliteOfflineFileIndex.snapshotChildrenTableName} '
      'WHERE account_key = ? AND folder_path = ? ORDER BY child_path',
      [key, '/'],
    );
    expect(children.map((row) => row['child_path']), [
      '/current.txt',
      '/published.txt',
    ]);
  });

  test('prunes superseded generations after atomic completion', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
    final cache = _cache(root);
    addTearDown(() async {
      await cache.close();
      await root.delete(recursive: true);
    });

    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/removed.txt')], total: 1),
      offset: 0,
      limit: 100,
      fetchedAt: _time(1),
    );
    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/kept.txt')], total: 2),
      offset: 0,
      limit: 1,
      fetchedAt: _time(2),
    );
    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/added.txt')], total: 2),
      offset: 1,
      limit: 1,
      fetchedAt: _time(3),
    );
    await cache.close();

    final database = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'cloud_cache', SqliteOfflineFileIndex.databaseFileName),
    );
    addTearDown(database.close);
    final key = accountCacheKey('reader@mail.ru');
    final generations = await database.rawQuery(
      'SELECT generation_id FROM '
      '${SqliteOfflineFileIndex.snapshotGenerationsTableName} '
      'WHERE account_key = ? AND folder_path = ?',
      [key, '/'],
    );
    expect(generations, hasLength(1));
    final children = await database.rawQuery(
      'SELECT child_path FROM '
      '${SqliteOfflineFileIndex.snapshotChildrenTableName} '
      'WHERE account_key = ? AND folder_path = ? ORDER BY child_path',
      [key, '/'],
    );
    expect(children.map((row) => row['child_path']), [
      '/added.txt',
      '/kept.txt',
    ]);
  });

  test(
    'exposes the first staging page and rejects an unexpected offset',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
      final cache = _cache(root);
      addTearDown(() async {
        await cache.close();
        await root.delete(recursive: true);
      });

      await cache.storePage(
        'reader@mail.ru',
        _page([_node('/one.txt')], total: 3),
        offset: 0,
        limit: 1,
        fetchedAt: _time(1),
      );
      final incomplete = await cache.readFolder('reader@mail.ru', '/');
      expect(incomplete!.complete, isFalse);
      expect(incomplete.page.items.map((item) => item.path), ['/one.txt']);
      expect(incomplete.page.totalCount, 3);

      await expectLater(
        cache.storePage(
          'reader@mail.ru',
          _page([_node('/three.txt')], total: 3),
          offset: 2,
          limit: 1,
          fetchedAt: _time(2),
        ),
        throwsA(isA<StateError>()),
      );
      final stillIncomplete = await cache.readFolder('reader@mail.ru', '/');
      expect(stillIncomplete!.page.items.map((item) => item.path), [
        '/one.txt',
      ]);
    },
  );

  test('publishes an empty folder as a complete snapshot', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
    final cache = _cache(root);
    addTearDown(() async {
      await cache.close();
      await root.delete(recursive: true);
    });

    await cache.storePage(
      'reader@mail.ru',
      _page(const [], total: 0),
      offset: 0,
      limit: 100,
      fetchedAt: _time(1),
    );
    final result = await cache.readFolder('reader@mail.ru', '/');
    expect(result!.complete, isTrue);
    expect(result.page.items, isEmpty);
    expect(result.page.totalCount, 0);
  });

  test('rejects a child outside the listed folder', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
    final cache = _cache(root);
    addTearDown(() async {
      await cache.close();
      await root.delete(recursive: true);
    });

    await expectLater(
      cache.storePage(
        'reader@mail.ru',
        CloudFolderPage(
          folder: const CloudNode(
            path: '/docs',
            name: 'docs',
            type: CloudNodeType.folder,
          ),
          items: [_node('/other/file.txt')],
          totalCount: 1,
          sort: CloudSort.nameAscending,
        ),
        fetchedAt: _time(1),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('upgrades v1 without recreating or losing offline rows', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
    final databasePath = p.join(
      root.path,
      'cloud_cache',
      SqliteOfflineFileIndex.databaseFileName,
    );
    final directory = Directory(p.dirname(databasePath));
    await directory.create(recursive: true);
    final database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, _) async {
          await database.execute('''
            CREATE TABLE offline_files (
              account_key TEXT NOT NULL,
              path TEXT NOT NULL,
              name TEXT NOT NULL,
              hash TEXT NOT NULL,
              size INTEGER NOT NULL CHECK (size >= 0),
              modified_at INTEGER,
              revision TEXT,
              global_revision TEXT,
              cached_at INTEGER NOT NULL,
              PRIMARY KEY (account_key, path)
            )
          ''');
          await database.execute('''
            CREATE INDEX offline_files_account_cached_at_idx
            ON offline_files (account_key, cached_at DESC, path ASC)
          ''');
        },
      ),
    );
    await database.insert('offline_files', {
      'account_key': accountCacheKey('reader@mail.ru'),
      'path': '/kept.txt',
      'name': 'kept.txt',
      'hash': '00112233445566778899AABBCCDDEEFF00112233',
      'size': 7,
      'cached_at': _time(1).microsecondsSinceEpoch,
    });
    await database.close();

    final index = _cache(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });
    expect((await index.list('reader@mail.ru')).single.path, '/kept.txt');
    expect(await index.readFolder('reader@mail.ru', '/'), isNull);
    await index.close();

    final migrated = await databaseFactoryFfi.openDatabase(databasePath);
    addTearDown(migrated.close);
    expect(await migrated.rawQuery('PRAGMA user_version'), [
      {'user_version': SqliteOfflineFileIndex.schemaVersion},
    ]);
    final tables = await migrated.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => row['name']);
    expect(names, contains('offline_files'));
    expect(names, contains(SqliteOfflineFileIndex.snapshotHeadsTableName));
    expect(names, contains(SqliteOfflineFileIndex.transientObjectsTableName));
  });

  test('reports malformed metadata rows as a state error', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-metadata');
    final cache = _cache(root);
    await cache.storePage(
      'reader@mail.ru',
      _page([_node('/file.txt')], total: 1),
      offset: 0,
      limit: 100,
      fetchedAt: _time(1),
    );
    await cache.close();

    final database = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'cloud_cache', SqliteOfflineFileIndex.databaseFileName),
    );
    await database.rawUpdate(
      'UPDATE ${SqliteOfflineFileIndex.snapshotGenerationsTableName} '
      'SET folder_modified_at = ?',
      ['bad'],
    );
    await database.close();

    final reopened = _cache(root);
    addTearDown(() async {
      await reopened.close();
      await root.delete(recursive: true);
    });
    await expectLater(
      reopened.readFolder('reader@mail.ru', '/'),
      throwsA(isA<StateError>()),
    );
  });
}

SqliteOfflineFileIndex _cache(Directory root) => SqliteOfflineFileIndex(
  rootProvider: FixedCacheRoot(root),
  databaseFactory: databaseFactoryFfi,
);

CloudFolderPage _page(List<CloudNode> items, {required int total}) =>
    CloudFolderPage(
      folder: _folder(),
      items: items,
      totalCount: total,
      sort: CloudSort.nameAscending,
    );

CloudNode _folder({
  String? kind,
  String? revision,
  String? globalRevision,
  String? tree,
  String? webLink,
  String? virusScan,
  int? fileCount,
  int? folderCount,
}) => CloudNode(
  path: '/',
  name: 'Cloud',
  type: CloudNodeType.folder,
  kind: kind,
  revision: revision,
  globalRevision: globalRevision,
  tree: tree,
  webLink: webLink,
  virusScan: virusScan,
  fileCount: fileCount,
  folderCount: folderCount,
);

CloudNode _node(
  String path, {
  String? name,
  int? size = 1,
  DateTime? modifiedAt,
  String? kind,
  String? hash,
  String? revision,
  String? globalRevision,
  String? tree,
  String? webLink,
  String? virusScan,
  int? fileCount,
  int? folderCount,
}) => CloudNode(
  path: path,
  name: name ?? p.basename(path),
  type: CloudNodeType.file,
  size: size,
  modifiedAt: modifiedAt,
  kind: kind,
  hash: hash,
  revision: revision,
  globalRevision: globalRevision,
  tree: tree,
  webLink: webLink,
  virusScan: virusScan,
  fileCount: fileCount,
  folderCount: folderCount,
);

CloudSession _metadataSession() => CloudSession(
  email: 'reader@mail.ru',
  accessToken: 'access',
  refreshToken: 'refresh',
  csrfToken: 'csrf',
  expiresAt: DateTime.utc(2027),
);

final class _MetadataAuthApi implements AuthApi {
  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => _metadataSession();

  @override
  Future<CloudSession> refresh(CloudSession session) async => session;

  @override
  void close() {}
}

final class _MetadataRaceBrowser implements BrowserRepository {
  _MetadataRaceBrowser(this._handler);

  final Future<CloudFolderPage> Function(int call) _handler;
  var _calls = 0;

  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) => _handler(++_calls);

  @override
  void close() {}
}

DateTime _time(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
