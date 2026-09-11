import 'dart:async';

import 'package:easy_cloud/core/errors/cloud_failure.dart';
import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:easy_cloud/features/browser/application/browser_repository.dart';
import 'package:easy_cloud/features/browser/data/cached_browser_repository.dart';
import 'package:easy_cloud/features/browser/domain/cloud_folder_page.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:easy_cloud/features/offline/application/cloud_metadata_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fetchedAt = DateTime.utc(2026, 9, 10, 12, 13, 14);
  final descending = const CloudSort(
    CloudSortField.name,
    CloudSortOrder.descending,
  );

  test('returns remote pages and stores exact paging arguments', () async {
    final auth = await _authenticated('reader@mail.ru');
    addTearDown(auth.close);
    final remotePage = _page(['/remote.txt'], total: 9, sort: descending);
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) async {
      return remotePage;
    });
    final cache = _FakeMetadataCache();
    final localClock = fetchedAt.toLocal();
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
      clock: () => localClock,
    );

    final result = await repository.listFolder(
      '/docs',
      offset: 0,
      limit: 7,
      sort: descending,
    );

    expect(result, same(remotePage));
    expect(result.source, CloudFolderPageSource.remote);
    expect(result.connectionFailure, isNull);
    expect(result.cachedAt, isNull);
    expect(result.snapshotComplete, isTrue);
    expect(remote.calls.single, ('/docs', 0, 7, descending));
    expect(cache.storeCalls, hasLength(1));
    final store = cache.storeCalls.single;
    expect(store.email, 'reader@mail.ru');
    expect(store.page, same(remotePage));
    expect(store.offset, 0);
    expect(store.limit, 7);
    expect(store.fetchedAt, fetchedAt);
    expect(store.fetchedAt.isUtc, isTrue);
  });

  test('does not store a stale sort response', () async {
    final auth = await _authenticated('reader@mail.ru');
    addTearDown(auth.close);
    final ascending = Completer<CloudFolderPage>();
    final descending = Completer<CloudFolderPage>();
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) {
      return sort == CloudSort.nameAscending
          ? ascending.future
          : descending.future;
    });
    final cache = _FakeMetadataCache();
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
    );

    final staleRequest = repository.listFolder('/docs');
    await Future<void>.delayed(Duration.zero);
    final currentRequest = repository.listFolder(
      '/docs',
      sort: const CloudSort(CloudSortField.name, CloudSortOrder.descending),
    );
    await Future<void>.delayed(Duration.zero);

    final currentPage = _page(
      ['/current.txt'],
      total: 1,
      sort: const CloudSort(CloudSortField.name, CloudSortOrder.descending),
    );
    descending.complete(currentPage);
    expect(await currentRequest, same(currentPage));

    final stalePage = _page(['/stale.txt'], total: 1);
    ascending.complete(stalePage);
    expect(await staleRequest, same(stalePage));

    expect(cache.storeCalls, hasLength(1));
    expect(cache.storeCalls.single.page, same(currentPage));
  });

  test('does not append a stale page after a new page-zero request', () async {
    final auth = await _authenticated('reader@mail.ru');
    addTearDown(auth.close);
    final firstPage = Completer<CloudFolderPage>();
    final laterPage = Completer<CloudFolderPage>();
    final secondPage = Completer<CloudFolderPage>();
    var pageZeroCalls = 0;
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) {
      if (offset == 0) {
        pageZeroCalls++;
        return pageZeroCalls == 1 ? firstPage.future : laterPage.future;
      }
      return secondPage.future;
    });
    final cache = _FakeMetadataCache();
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
    );

    final oldFirst = repository.listFolder('/', limit: 2);
    await Future<void>.delayed(Duration.zero);
    final oldSecond = repository.listFolder('/', offset: 2, limit: 2);
    await Future<void>.delayed(Duration.zero);
    final newFirst = repository.listFolder('/', limit: 2);
    await Future<void>.delayed(Duration.zero);

    final newPage = _page(['/new.txt'], total: 1);
    laterPage.complete(newPage);
    expect(await newFirst, same(newPage));

    secondPage.complete(_page(['/old-page-2.txt'], total: 3));
    firstPage.complete(_page(['/old-page-1.txt'], total: 3));
    await Future.wait([oldFirst, oldSecond]);

    expect(cache.storeCalls, hasLength(1));
    expect(cache.storeCalls.single.page, same(newPage));
  });

  test('does not store a page without a matching page-zero request', () async {
    final auth = await _authenticated('reader@mail.ru');
    addTearDown(auth.close);
    final page = _page(['/page.txt'], total: 2);
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) async {
      return page;
    });
    final cache = _FakeMetadataCache();
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
    );

    expect(await repository.listFolder('/', offset: 1, limit: 1), same(page));
    expect(cache.storeCalls, isEmpty);
  });

  test('hides a cache write failure behind a successful remote page', () async {
    final auth = await _authenticated('reader@mail.ru');
    addTearDown(auth.close);
    final remotePage = _page(['/remote.txt'], total: 1);
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) async {
      return remotePage;
    });
    final cache = _FakeMetadataCache()
      ..storeError = StateError('private cache details');
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
      clock: () => fetchedAt,
    );

    expect(await repository.listFolder('/'), same(remotePage));
    expect(cache.storeCalls, hasLength(1));
  });

  test('falls back on a network failure with cache metadata', () async {
    final auth = await _authenticated('reader@mail.ru');
    addTearDown(auth.close);
    final failure = const CloudFailure(CloudFailureType.network, 'offline');
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) async {
      throw failure;
    });
    final cachedPage = _page(['/cached.txt'], total: 8, sort: descending);
    final cache = _FakeMetadataCache()
      ..readResult = CachedCloudFolderPage(
        page: cachedPage,
        complete: true,
        fetchedAt: fetchedAt,
      );
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
    );

    final result = await repository.listFolder(
      '/docs',
      offset: 3,
      limit: 2,
      sort: descending,
    );

    expect(result.source, CloudFolderPageSource.cache);
    expect(result.connectionFailure, same(failure));
    expect(result.cachedAt, fetchedAt);
    expect(result.snapshotComplete, isTrue);
    expect(result.items, same(cachedPage.items));
    expect(result.totalCount, 8);
    final read = cache.readCalls.single;
    expect(read.email, 'reader@mail.ru');
    expect(read.path, '/docs');
    expect(read.offset, 3);
    expect(read.limit, 2);
    expect(read.sort, descending);
    expect(cache.storeCalls, isEmpty);
  });

  test('falls back on a timeout failure', () async {
    final auth = await _authenticated('reader@mail.ru');
    addTearDown(auth.close);
    final failure = const CloudFailure(CloudFailureType.timeout, 'timed out');
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) async {
      throw failure;
    });
    final cache = _FakeMetadataCache()
      ..readResult = CachedCloudFolderPage(
        page: _page(['/cached.txt'], total: 1),
        complete: true,
        fetchedAt: fetchedAt,
      );
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
    );

    final result = await repository.listFolder('/');

    expect(result.source, CloudFolderPageSource.cache);
    expect(result.connectionFailure, same(failure));
  });

  for (final type in [
    CloudFailureType.authRequired,
    CloudFailureType.service,
    CloudFailureType.notFound,
    CloudFailureType.permissionDenied,
    CloudFailureType.invalidResponse,
  ]) {
    test('does not mask $type', () async {
      final auth = await _authenticated('reader@mail.ru');
      addTearDown(auth.close);
      final failure = CloudFailure(type, 'remote $type');
      final remote = _FakeBrowserRepository((
        path, {
        offset = 0,
        limit = 100,
        sort = CloudSort.nameAscending,
      }) async {
        throw failure;
      });
      final cache = _FakeMetadataCache()
        ..readResult = CachedCloudFolderPage(
          page: _page(['/must-not-show.txt'], total: 1),
          complete: true,
          fetchedAt: fetchedAt,
        );
      final repository = CachedBrowserRepository(
        remote: remote,
        cache: cache,
        authRepository: auth,
      );

      await expectLater(repository.listFolder('/'), throwsA(same(failure)));
      expect(cache.readCalls, isEmpty);
    });
  }

  test('rethrows the original network failure when cache is absent', () async {
    final auth = await _authenticated('reader@mail.ru');
    addTearDown(auth.close);
    final failure = const CloudFailure(CloudFailureType.network, 'offline');
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) async {
      throw failure;
    });
    final cache = _FakeMetadataCache();
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
    );

    await expectLater(repository.listFolder('/'), throwsA(same(failure)));
    expect(cache.readCalls, hasLength(1));
  });

  test(
    'hides a cache read failure behind the original network failure',
    () async {
      final auth = await _authenticated('reader@mail.ru');
      addTearDown(auth.close);
      final failure = const CloudFailure(CloudFailureType.network, 'offline');
      final remote = _FakeBrowserRepository((
        path, {
        offset = 0,
        limit = 100,
        sort = CloudSort.nameAscending,
      }) async {
        throw failure;
      });
      final cache = _FakeMetadataCache()
        ..readError = StateError('private cache details');
      final repository = CachedBrowserRepository(
        remote: remote,
        cache: cache,
        authRepository: auth,
      );

      await expectLater(repository.listFolder('/'), throwsA(same(failure)));
    },
  );

  test(
    'bounds incomplete cached pages to items available through the page',
    () async {
      final auth = await _authenticated('reader@mail.ru');
      addTearDown(auth.close);
      final failure = const CloudFailure(CloudFailureType.network, 'offline');
      final remote = _FakeBrowserRepository((
        path, {
        offset = 0,
        limit = 100,
        sort = CloudSort.nameAscending,
      }) async {
        throw failure;
      });
      final cache = _FakeMetadataCache()
        ..readResult = CachedCloudFolderPage(
          page: _page(['/one.txt'], total: 20),
          complete: false,
          fetchedAt: fetchedAt,
        );
      final repository = CachedBrowserRepository(
        remote: remote,
        cache: cache,
        authRepository: auth,
      );

      final result = await repository.listFolder('/', offset: 2, limit: 1);

      expect(result.source, CloudFolderPageSource.cache);
      expect(result.snapshotComplete, isFalse);
      expect(result.totalCount, 3);
    },
  );

  test('does not write a successful page after an account switch', () async {
    final auth = await _authenticated('first@mail.ru');
    addTearDown(auth.close);
    final remoteResult = Completer<CloudFolderPage>();
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) {
      return remoteResult.future;
    });
    final cache = _FakeMetadataCache();
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
    );

    final operation = repository.listFolder('/');
    await Future<void>.delayed(Duration.zero);
    await auth.login(email: 'second@mail.ru', password: 'password');
    final remotePage = _page(['/remote.txt'], total: 1);
    remoteResult.complete(remotePage);

    expect(await operation, same(remotePage));
    expect(cache.storeCalls, isEmpty);
  });

  test('does not read or write a stale account scope', () async {
    final auth = await _authenticated('first@mail.ru');
    addTearDown(auth.close);
    final remoteResult = Completer<CloudFolderPage>();
    final failure = const CloudFailure(CloudFailureType.network, 'offline');
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) {
      return remoteResult.future;
    });
    final cache = _FakeMetadataCache()
      ..readResult = CachedCloudFolderPage(
        page: _page(['/wrong-account.txt'], total: 1),
        complete: true,
        fetchedAt: fetchedAt,
      );
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
    );

    final operation = repository.listFolder('/');
    await Future<void>.delayed(Duration.zero);
    await auth.login(email: 'second@mail.ru', password: 'password');
    remoteResult.completeError(failure);

    await expectLater(operation, throwsA(same(failure)));
    expect(cache.storeCalls, isEmpty);
    expect(cache.readCalls, isEmpty);
  });

  test('close closes only the wrapped repository', () async {
    final auth = await _authenticated('reader@mail.ru');
    addTearDown(auth.close);
    final remote = _FakeBrowserRepository((
      path, {
      offset = 0,
      limit = 100,
      sort = CloudSort.nameAscending,
    }) async {
      return _page(['/remote.txt'], total: 1);
    });
    final cache = _FakeMetadataCache();
    final repository = CachedBrowserRepository(
      remote: remote,
      cache: cache,
      authRepository: auth,
    );

    repository.close();
    repository.close();

    expect(remote.closeCalls, 1);
    expect(cache.closeCalls, 0);
  });
}

Future<AuthRepository> _authenticated(String email) async {
  final auth = AuthRepository(
    api: _AuthApi(),
    store: MemorySessionStore()..session = _session(email),
  );
  await auth.restore();
  return auth;
}

CloudSession _session(String email) => CloudSession(
  email: email,
  accessToken: 'access',
  refreshToken: 'refresh',
  csrfToken: 'csrf',
  expiresAt: DateTime.utc(2027),
);

CloudFolderPage _page(
  List<String> paths, {
  required int total,
  CloudSort sort = CloudSort.nameAscending,
}) => CloudFolderPage(
  folder: const CloudNode(path: '/', name: 'Cloud', type: CloudNodeType.folder),
  items: [
    for (final path in paths)
      CloudNode(path: path, name: path.substring(1), type: CloudNodeType.file),
  ],
  totalCount: total,
  sort: sort,
);

typedef _ListHandler =
    Future<CloudFolderPage> Function(
      String path, {
      int offset,
      int limit,
      CloudSort sort,
    });

final class _FakeBrowserRepository implements BrowserRepository {
  _FakeBrowserRepository(this.handler);

  final _ListHandler handler;
  final calls = <(String, int, int, CloudSort)>[];
  int closeCalls = 0;

  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) {
    calls.add((path, offset, limit, sort));
    return handler(path, offset: offset, limit: limit, sort: sort);
  }

  @override
  void close() => closeCalls++;
}

final class _FakeMetadataCache implements CloudMetadataCache {
  CachedCloudFolderPage? readResult;
  Object? storeError;
  Object? readError;
  final storeCalls = <_StoreCall>[];
  final readCalls = <_ReadCall>[];
  int closeCalls = 0;

  @override
  Future<void> storePage(
    String email,
    CloudFolderPage page, {
    int offset = 0,
    int limit = cloudFolderPageSize,
    required DateTime fetchedAt,
  }) async {
    storeCalls.add(
      _StoreCall(
        email: email,
        page: page,
        offset: offset,
        limit: limit,
        fetchedAt: fetchedAt,
      ),
    );
    final error = storeError;
    if (error != null) throw error;
  }

  @override
  Future<CachedCloudFolderPage?> readFolder(
    String email,
    String path, {
    CloudSort sort = CloudSort.nameAscending,
    int offset = 0,
    int limit = cloudFolderPageSize,
  }) async {
    readCalls.add(
      _ReadCall(
        email: email,
        path: path,
        offset: offset,
        limit: limit,
        sort: sort,
      ),
    );
    final error = readError;
    if (error != null) throw error;
    return readResult;
  }

  @override
  Future<void> close() async => closeCalls++;
}

final class _StoreCall {
  const _StoreCall({
    required this.email,
    required this.page,
    required this.offset,
    required this.limit,
    required this.fetchedAt,
  });

  final String email;
  final CloudFolderPage page;
  final int offset;
  final int limit;
  final DateTime fetchedAt;
}

final class _ReadCall {
  const _ReadCall({
    required this.email,
    required this.path,
    required this.offset,
    required this.limit,
    required this.sort,
  });

  final String email;
  final String path;
  final int offset;
  final int limit;
  final CloudSort sort;
}

final class _AuthApi implements AuthApi {
  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => _session(email);

  @override
  Future<CloudSession> refresh(CloudSession session) async => session;

  @override
  void close() {}
}
