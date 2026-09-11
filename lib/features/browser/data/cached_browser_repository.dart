import '../../../core/errors/cloud_failure.dart';
import '../../auth/application/auth_repository.dart';
import '../../offline/application/cloud_metadata_cache.dart';
import '../../offline/domain/offline_file_record.dart';
import '../application/browser_repository.dart';
import '../domain/cloud_folder_page.dart';
import '../domain/cloud_sort.dart';

/// A remote-first browser repository with account-scoped metadata fallback.
final class CachedBrowserRepository implements BrowserRepository {
  CachedBrowserRepository({
    required BrowserRepository remote,
    required CloudMetadataCache cache,
    required AuthRepository authRepository,
    DateTime Function()? clock,
  }) : _remote = remote,
       _cache = cache,
       _authRepository = authRepository,
       _clock = clock ?? DateTime.now;

  final BrowserRepository _remote;
  final CloudMetadataCache _cache;
  final AuthRepository _authRepository;
  final DateTime Function() _clock;

  bool _closed = false;
  var _nextRequestSequence = 0;
  final _activeSequences = <_BrowserFolderKey, _BrowserRequestSequence>{};

  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async {
    final scope = _captureScope();
    final sequence = _captureRequestSequence(
      scope,
      path: path,
      offset: offset,
      limit: limit,
      sort: sort,
    );
    try {
      final page = await _remote.listFolder(
        path,
        offset: offset,
        limit: limit,
        sort: sort,
      );
      if (scope != null && _canWritePage(scope, sequence)) {
        try {
          await _cache.storePage(
            scope.email,
            page,
            offset: offset,
            limit: limit,
            fetchedAt: _clock().toUtc(),
          );
        } catch (_) {
          // A cache write must never turn a successful remote page into a
          // failure.
        }
      }
      return page;
    } on CloudFailure catch (failure, stackTrace) {
      if (!_canFallback(failure) ||
          scope == null ||
          !_isCurrentRequest(scope, sequence)) {
        Error.throwWithStackTrace(failure, stackTrace);
      }

      try {
        final cached = await _cache.readFolder(
          scope.email,
          path,
          sort: sort,
          offset: offset,
          limit: limit,
        );
        if (cached != null && _isCurrentRequest(scope, sequence)) {
          return CloudFolderPage(
            folder: cached.page.folder,
            items: cached.page.items,
            totalCount: _cachedTotalCount(cached, offset: offset),
            sort: cached.page.sort,
            source: CloudFolderPageSource.cache,
            connectionFailure: failure,
            cachedAt: cached.fetchedAt,
            snapshotComplete: cached.complete,
          );
        }
      } catch (_) {
        // Cache failures are deliberately hidden behind the original remote
        // failure.
      }
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  bool _canFallback(CloudFailure failure) =>
      failure.type == CloudFailureType.network ||
      failure.type == CloudFailureType.timeout;

  _BrowserSessionScope? _captureScope() {
    final session = _authRepository.currentSession;
    if (session == null) return null;
    return _BrowserSessionScope(
      email: session.email,
      epoch: _authRepository.sessionEpoch,
    );
  }

  _BrowserRequestSequence? _captureRequestSequence(
    _BrowserSessionScope? scope, {
    required String path,
    required int offset,
    required int limit,
    required CloudSort sort,
  }) {
    if (scope == null) return null;
    final key = _BrowserFolderKey(
      epoch: scope.epoch,
      email: _accountIdentity(scope.email),
      path: _canonicalPathForSequence(path),
    );
    if (offset == 0) {
      final sequence = _BrowserRequestSequence(
        key: key,
        id: ++_nextRequestSequence,
        sort: sort,
        limit: limit,
      );
      _activeSequences[key] = sequence;
      return sequence;
    }

    final active = _activeSequences[key];
    if (active == null || active.sort != sort || active.limit != limit) {
      // A page without a matching page-zero request is not safe to append to
      // any staging generation. It may still be returned from the remote
      // repository, but must not mutate the cache.
      return null;
    }
    return active;
  }

  bool _canWritePage(
    _BrowserSessionScope? scope,
    _BrowserRequestSequence? sequence,
  ) => sequence != null && _isCurrentRequest(scope, sequence);

  bool _isCurrentRequest(
    _BrowserSessionScope? scope,
    _BrowserRequestSequence? sequence,
  ) {
    if (scope == null || !_isCurrentScope(scope)) return false;
    if (sequence == null) return true;
    return identical(_activeSequences[sequence.key], sequence);
  }

  String _canonicalPathForSequence(String path) {
    try {
      return normalizeOfflineRemotePath(path);
    } on ArgumentError {
      // The remote repository remains authoritative for malformed input. A
      // raw fallback only prevents unrelated valid requests from sharing a
      // sequence key before the cache write is rejected.
      return path;
    }
  }

  bool _isCurrentScope(_BrowserSessionScope scope) {
    final session = _authRepository.currentSession;
    return session != null &&
        _authRepository.sessionEpoch == scope.epoch &&
        _accountIdentity(session.email) == _accountIdentity(scope.email);
  }

  int _cachedTotalCount(CachedCloudFolderPage cached, {required int offset}) {
    if (cached.complete) return cached.page.totalCount;

    final advertisedCount = cached.page.totalCount;
    final availableThroughPage = offset + cached.page.items.length;
    if (advertisedCount < 0 || availableThroughPage < 0) {
      throw StateError('Cached folder page has an invalid total count.');
    }
    return advertisedCount < availableThroughPage
        ? advertisedCount
        : availableThroughPage;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _remote.close();
  }
}

final class _BrowserSessionScope {
  const _BrowserSessionScope({required this.email, required this.epoch});

  final String email;
  final int epoch;
}

final class _BrowserFolderKey {
  const _BrowserFolderKey({
    required this.epoch,
    required this.email,
    required this.path,
  });

  final int epoch;
  final String email;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is _BrowserFolderKey &&
      other.epoch == epoch &&
      other.email == email &&
      other.path == path;

  @override
  int get hashCode => Object.hash(epoch, email, path);
}

final class _BrowserRequestSequence {
  const _BrowserRequestSequence({
    required this.key,
    required this.id,
    required this.sort,
    required this.limit,
  });

  final _BrowserFolderKey key;
  final int id;
  final CloudSort sort;
  final int limit;
}

String _accountIdentity(String email) => email.trim().toLowerCase();
