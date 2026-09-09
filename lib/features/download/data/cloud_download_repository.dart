import 'dart:async';
import 'dart:io';

import '../../../cloud_mail/api/cloud_mail_api.dart';
import '../../../cloud_mail/probe/cloud_hash.dart';
import '../../../features/auth/application/auth_repository.dart';
import '../../../features/auth/domain/auth_failure.dart';
import '../../../features/auth/domain/cloud_session.dart';
import '../../../features/browser/domain/cloud_node.dart';
import '../../../local/cache/application_cache_root.dart';
import '../../../local/cache/content_addressed_file_cache.dart';
import '../application/download_repository.dart';
import '../domain/download.dart';

typedef DownloadCacheFactory = ContentAddressedFileCache Function(String email);

final class CloudDownloadRepository implements DownloadRepository {
  CloudDownloadRepository({
    required CloudMailApi api,
    required DownloadTransport transport,
    required AuthRepository authRepository,
    DownloadCacheFactory? cacheFactory,
    Directory? cacheRoot,
    CacheRootProvider? rootProvider,
  }) : _api = api,
       _transport = transport,
       _authRepository = authRepository,
       _cacheFactory =
           cacheFactory ??
           ((email) => ContentAddressedFileCache(
             email: email,
             root: cacheRoot,
             rootProvider: rootProvider,
           )) {
    if (cacheFactory != null && (cacheRoot != null || rootProvider != null)) {
      throw ArgumentError(
        'cacheFactory cannot be combined with cacheRoot or rootProvider.',
      );
    }
  }

  final CloudMailApi _api;
  final DownloadTransport _transport;
  final AuthRepository _authRepository;
  final DownloadCacheFactory _cacheFactory;

  bool _closed = false;
  final _active = <_DownloadOperation>{};
  final _coordinator = _DownloadCoordinator();

  @override
  DownloadHandle start(CloudNode node) {
    if (_closed) throw StateError('DownloadRepository is closed.');
    late final _DownloadOperation operation;
    operation = _DownloadOperation(
      node: node,
      api: _api,
      transport: _transport,
      authRepository: _authRepository,
      cacheFactory: _cacheFactory,
      coordinator: _coordinator,
      onFinished: () => _active.remove(operation),
    );
    _active.add(operation);
    operation.start();
    return operation.handle;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final operation in _active.toList(growable: false)) {
      operation.cancel();
    }
    _transport.close();
  }
}

final class _DownloadOperation {
  _DownloadOperation({
    required this.node,
    required this.api,
    required this.transport,
    required this.authRepository,
    required this.cacheFactory,
    required this.coordinator,
    required this.onFinished,
  }) {
    handle = _DownloadHandle(
      progress: _progress.stream,
      result: _result.future,
      onCancel: _cancel,
    );
  }

  final CloudNode node;
  final CloudMailApi api;
  final DownloadTransport transport;
  final AuthRepository authRepository;
  final DownloadCacheFactory cacheFactory;
  final _DownloadCoordinator coordinator;
  final void Function() onFinished;
  final DownloadCancellationToken cancellation = DownloadCancellationToken();
  final _progress = StreamController<DownloadProgress>.broadcast(sync: true);
  final _result = Completer<File>();

  late final DownloadHandle handle;
  bool _finished = false;

  void start() {
    // Do not emit the first event before the caller has a chance to subscribe.
    unawaited(Future<void>.microtask(_run));
  }

  void _cancel() {
    if (_finished) return;
    cancellation.cancel();
  }

  void cancel() => _cancel();

  Future<void> _run() async {
    try {
      _emit(
        const DownloadProgress(
          phase: DownloadPhase.resolving,
          bytes: 0,
          total: null,
          resumed: false,
        ),
      );
      final scope = await _requireSession();
      cancellation.throwIfCancelled();

      final freshNode = await _stat(node.path);
      cancellation.throwIfCancelled();
      _ensureSession(scope);
      if (_normalizePath(freshNode.path) != _normalizePath(node.path)) {
        throw const DownloadFailure(
          DownloadFailureType.invalidResponse,
          'Mail.ru вернул метаданные другого файла.',
        );
      }
      final metadata = _validatedMetadata(freshNode);
      final cache = cacheFactory(scope.session.email);
      final release = await coordinator.acquire(
        '${cache.accountDirectoryName}:${metadata.hash}',
        cancellation,
      );
      try {
        final cached = await cache.lookup(
          metadata.hash,
          expectedSize: metadata.size,
        );
        cancellation.throwIfCancelled();
        _ensureSession(scope);
        if (cached != null) {
          final cachedHash = await calculateCloudFileHash(cached);
          cancellation.throwIfCancelled();
          if (_sameHash(cachedHash, metadata.hash)) {
            _emit(
              DownloadProgress(
                phase: DownloadPhase.committed,
                bytes: metadata.size,
                total: metadata.size,
                resumed: false,
                cacheHit: true,
              ),
            );
            _succeed(cached);
            return;
          }
          await cache.discardObject(metadata.hash);
        } else {
          // A size mismatch is also a stale object. Removing it here is needed
          // because ContentAddressedFileCache.commit preserves existing objects.
          await cache.discardObject(metadata.hash);
        }

        cancellation.throwIfCancelled();
        final partFile = await cache.partFile(metadata.hash);
        cancellation.throwIfCancelled();
        final request = DownloadRequest(
          remotePath: freshNode.path,
          partFile: partFile,
          expectedSize: metadata.size,
        );
        var receivedProgress = false;
        var lastReceivedBytes = -1;
        var lastReceivedResumed = false;
        final result = await transport.download(
          request,
          cancellation: cancellation,
          onProgress: (progress) {
            receivedProgress = true;
            lastReceivedBytes = progress.bytes;
            lastReceivedResumed = progress.resumed;
            _emit(
              DownloadProgress(
                phase: DownloadPhase.receiving,
                bytes: progress.bytes,
                total: metadata.size,
                resumed: progress.resumed,
              ),
            );
          },
        );
        cancellation.throwIfCancelled();
        try {
          _ensureSession(scope);
        } on DownloadCancelled {
          await _deleteQuietly(partFile);
          rethrow;
        }
        if (!receivedProgress ||
            lastReceivedBytes != result.bytes ||
            lastReceivedResumed != result.resumed) {
          _emit(
            DownloadProgress(
              phase: DownloadPhase.receiving,
              bytes: result.bytes,
              total: metadata.size,
              resumed: result.resumed,
            ),
          );
        }

        _emit(
          DownloadProgress(
            phase: DownloadPhase.verifying,
            bytes: result.bytes,
            total: metadata.size,
            resumed: result.resumed,
          ),
        );
        final actualSize = await partFile.length();
        cancellation.throwIfCancelled();
        if (actualSize != metadata.size) {
          await _deleteQuietly(partFile);
          throw DownloadIntegrityFailure(
            'Размер загруженного файла не совпадает с метаданными.',
            expectedSize: metadata.size,
            actualSize: actualSize,
          );
        }
        final actualHash = await calculateCloudFileHash(partFile);
        cancellation.throwIfCancelled();
        if (!_sameHash(actualHash, metadata.hash)) {
          await _deleteQuietly(partFile);
          throw DownloadIntegrityFailure(
            'Хеш загруженного файла не совпадает с метаданными.',
            expectedHash: metadata.hash,
            actualHash: actualHash,
          );
        }

        await cache.commit(metadata.hash, partFile);
        cancellation.throwIfCancelled();
        _ensureSession(scope);
        final object = await cache.objectFile(metadata.hash);
        _emit(
          DownloadProgress(
            phase: DownloadPhase.committed,
            bytes: metadata.size,
            total: metadata.size,
            resumed: result.resumed,
          ),
        );
        _succeed(object);
        return;
      } finally {
        release();
      }
    } catch (error, stackTrace) {
      final failure = cancellation.isCancelled && error is! DownloadCancelled
          ? const DownloadCancelled()
          : error;
      _fail(failure, stackTrace);
    } finally {
      _finished = true;
      try {
        await _progress.close();
      } catch (_) {
        // A progress listener must not turn a settled result into an
        // unhandled asynchronous error.
      }
      try {
        await cancellation.close();
      } catch (_) {
        // The result and its typed failure have already been published.
      }
      onFinished();
    }
  }

  Future<_DownloadSessionScope> _requireSession() async {
    final epoch = authRepository.sessionEpoch;
    try {
      final session = await authRepository.requireFreshSession();
      final scope = _DownloadSessionScope(session: session, epoch: epoch);
      _ensureSession(scope);
      return scope;
    } on AuthFailure catch (failure) {
      throw DownloadFailure(
        switch (failure.type) {
          AuthFailureType.network => DownloadFailureType.network,
          AuthFailureType.authRequired || AuthFailureType.invalidCredentials =>
            DownloadFailureType.authRequired,
          AuthFailureType.invalidResponse =>
            DownloadFailureType.invalidResponse,
          AuthFailureType.service ||
          AuthFailureType.secureStorage => DownloadFailureType.service,
        },
        failure.message,
        cause: failure,
      );
    }
  }

  void _ensureSession(_DownloadSessionScope scope) {
    final current = authRepository.currentSession;
    if (authRepository.sessionEpoch != scope.epoch ||
        current == null ||
        current.email.trim().toLowerCase() !=
            scope.session.email.trim().toLowerCase()) {
      throw const DownloadCancelled();
    }
  }

  String _normalizePath(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return normalized.length > 1 && normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }

  Future<CloudNode> _stat(String path) async {
    return api.stat(path);
  }

  _DownloadMetadata _validatedMetadata(CloudNode freshNode) {
    final size = freshNode.size;
    final hash = freshNode.hash?.trim().toUpperCase();
    if (freshNode.type != CloudNodeType.file ||
        size == null ||
        size < 0 ||
        hash == null ||
        !RegExp(r'^[0-9A-F]{40}$').hasMatch(hash)) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Mail.ru вернул неполные метаданные файла.',
      );
    }
    return _DownloadMetadata(size: size, hash: hash);
  }

  bool _sameHash(String actual, String expected) =>
      actual.trim().toUpperCase() == expected;

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Preserve the integrity failure. The cache object is never committed
      // before verification, so no final object can be exposed here.
    }
  }

  void _emit(DownloadProgress progress) {
    if (!_progress.isClosed) _progress.add(progress);
  }

  File _succeed(File file) {
    if (!_result.isCompleted) _result.complete(file);
    return file;
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (!_result.isCompleted) _result.completeError(error, stackTrace);
  }
}

final class _DownloadHandle implements DownloadHandle {
  _DownloadHandle({
    required this.progress,
    required this.result,
    required void Function() onCancel,
  }) : _onCancel = onCancel;

  @override
  final Stream<DownloadProgress> progress;

  @override
  final Future<File> result;

  final void Function() _onCancel;

  @override
  void cancel() => _onCancel();
}

final class _DownloadMetadata {
  const _DownloadMetadata({required this.size, required this.hash});

  final int size;
  final String hash;
}

final class _DownloadSessionScope {
  const _DownloadSessionScope({required this.session, required this.epoch});

  final CloudSession session;
  final int epoch;
}

final class _DownloadCoordinator {
  final _tails = <String, Future<void>>{};

  Future<void Function()> acquire(
    String key,
    DownloadCancellationToken cancellation,
  ) async {
    final previous = _tails[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _tails[key] = gate.future;
    await previous;
    try {
      cancellation.throwIfCancelled();
    } catch (_) {
      gate.complete();
      if (identical(_tails[key], gate.future)) _tails.remove(key);
      rethrow;
    }

    var released = false;
    return () {
      if (released) return;
      released = true;
      gate.complete();
      if (identical(_tails[key], gate.future)) _tails.remove(key);
    };
  }
}
