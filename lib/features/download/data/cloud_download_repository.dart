import 'dart:async';
import 'dart:io';

import '../../../cloud_mail/api/cloud_mail_api.dart';
import '../../../cloud_mail/probe/cloud_hash.dart';
import '../../../features/auth/application/auth_repository.dart';
import '../../../features/auth/domain/auth_failure.dart';
import '../../../features/auth/domain/cloud_session.dart';
import '../../../features/browser/domain/cloud_node.dart';
import '../../../local/cache/application_cache_root.dart';
import '../../../local/cache/cloud_cache_coordinator.dart';
import '../../../local/cache/content_addressed_file_cache.dart';
import '../../offline/application/offline_file_index.dart';
import '../application/download_repository.dart';
import '../domain/download.dart';

typedef DownloadCacheFactory = ContentAddressedFileCache Function(String email);

const _transientCacheCapBytes = 524288000;

final class CloudDownloadRepository implements DownloadRepository {
  CloudDownloadRepository({
    required CloudMailApi api,
    required DownloadTransport transport,
    required AuthRepository authRepository,
    required OfflineTargetStorage offlineFileIndex,
    DownloadCacheFactory? cacheFactory,
    Directory? cacheRoot,
    CacheRootProvider? rootProvider,
    required CloudCacheCoordinator coordinator,
  }) : _api = api,
       _transport = transport,
       _authRepository = authRepository,
       _offlineFileIndex = offlineFileIndex,
       _targetIndex = offlineFileIndex,
       _transientObjectIndex = offlineFileIndex is TransientObjectIndex
           ? offlineFileIndex as TransientObjectIndex
           : null,
       _cacheFactory =
           cacheFactory ??
           ((email) => ContentAddressedFileCache(
             email: email,
             root: cacheRoot,
             rootProvider: rootProvider,
           )),
       _coordinator = coordinator,
       _targetCoordinator = coordinator,
       _reconciliationCoordinator = coordinator,
       _pruneCoordinator = coordinator {
    if (cacheFactory != null && (cacheRoot != null || rootProvider != null)) {
      throw ArgumentError(
        'cacheFactory cannot be combined with cacheRoot or rootProvider.',
      );
    }
  }

  final CloudMailApi _api;
  final DownloadTransport _transport;
  final AuthRepository _authRepository;
  final OfflineFileIndex _offlineFileIndex;
  final OfflineTargetIndex _targetIndex;
  final TransientObjectIndex? _transientObjectIndex;
  final DownloadCacheFactory _cacheFactory;

  bool _closed = false;
  var _openGeneration = 0;
  _ProtectedOpen? _protectedOpen;
  final _active = <_DownloadOperation>{};
  final _activeOfflineRemovals = <_TrackedRepositoryOperation>{};
  final _activeTargetRemovals = <_TrackedRepositoryOperation>{};
  final _activeReconciliations = <_TrackedRepositoryOperation>{};
  Future<void>? _closeFuture;
  final CloudCacheCoordinator _coordinator;
  final CloudCacheCoordinator _targetCoordinator;
  final CloudCacheCoordinator _reconciliationCoordinator;
  final CloudCacheCoordinator _pruneCoordinator;

  @override
  DownloadHandle start(CloudNode node) {
    return _startOperation(node, mode: _DownloadMode.direct);
  }

  @override
  DownloadHandle startOpen(CloudNode node) {
    if (_closed) throw StateError('DownloadRepository is closed.');
    final releasedProtection = _protectedOpen;
    _protectedOpen = null;
    final generation = ++_openGeneration;
    return _startOperation(
      node,
      mode: _DownloadMode.open,
      openScope: _captureSessionScope(),
      openGeneration: generation,
      releasedProtection: releasedProtection,
    );
  }

  @override
  DownloadHandle startTarget(
    CloudNode node, {
    required String targetPath,
    required String expectedEmail,
    required String targetIncarnation,
  }) {
    if (_closed) throw StateError('DownloadRepository is closed.');
    final normalizedTargetPath = _validateTargetStart(node, targetPath);
    final normalizedEmail = _validateExpectedAccount(expectedEmail);
    final normalizedIncarnation = normalizeOfflineTargetIncarnation(
      targetIncarnation,
    );
    final expectedSessionEpoch = _validateCurrentTargetSession(normalizedEmail);
    return _startOperation(
      node,
      mode: _DownloadMode.target,
      targetPath: normalizedTargetPath,
      expectedTargetEmail: normalizedEmail,
      expectedTargetIncarnation: normalizedIncarnation,
      expectedTargetSessionEpoch: expectedSessionEpoch,
    );
  }

  DownloadHandle _startOperation(
    CloudNode node, {
    required _DownloadMode mode,
    String? targetPath,
    String? expectedTargetEmail,
    String? expectedTargetIncarnation,
    int? expectedTargetSessionEpoch,
    _DownloadSessionScope? openScope,
    int? openGeneration,
    _ProtectedOpen? releasedProtection,
  }) {
    if (_closed) throw StateError('DownloadRepository is closed.');
    late final _DownloadOperation operation;
    operation = _DownloadOperation(
      node: node,
      mode: mode,
      targetPath: targetPath,
      expectedTargetEmail: expectedTargetEmail,
      expectedTargetIncarnation: expectedTargetIncarnation,
      expectedTargetSessionEpoch: expectedTargetSessionEpoch,
      openScope: openScope,
      api: _api,
      transport: _transport,
      authRepository: _authRepository,
      offlineFileIndex: _offlineFileIndex,
      targetIndex: _targetIndex,
      cacheFactory: _cacheFactory,
      coordinator: _coordinator,
      targetCoordinator: _targetCoordinator,
      onOpenVerified: mode != _DownloadMode.open
          ? null
          : (scope, metadata, cancellation) => _touchTransient(
              scope,
              metadata,
              cancellation,
              generation: openGeneration!,
            ),
      onOpenPrepared: mode != _DownloadMode.open
          ? null
          : (scope, metadata, cancellation) => _finishOpen(
              scope,
              metadata,
              cancellation,
              generation: openGeneration!,
              releasedProtection: releasedProtection,
            ),
      onFinished: (succeeded) {
        if (mode == _DownloadMode.open && !succeeded) {
          _discardOpenProtection(openGeneration!);
        }
        _active.remove(operation);
      },
    );
    _active.add(operation);
    operation.start();
    return operation.handle;
  }

  String _validateTargetStart(CloudNode node, String targetPath) {
    if (node.type != CloudNodeType.file) {
      throw ArgumentError.value(
        node.type,
        'node.type',
        'Only files can be downloaded into an offline target.',
      );
    }
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final normalizedFilePath = normalizeOfflineRemotePath(node.path);
    if (!_isFileUnderTarget(normalizedTargetPath, normalizedFilePath)) {
      throw ArgumentError.value(
        node.path,
        'node.path',
        'The file must belong to the target folder.',
      );
    }
    return normalizedTargetPath;
  }

  String _validateExpectedAccount(String email) {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty) {
      throw ArgumentError.value(email, 'expectedEmail', 'Account is required.');
    }
    return normalized;
  }

  int _validateCurrentTargetSession(String expectedEmail) {
    final session = _authRepository.currentSession;
    if (session == null) {
      throw const DownloadFailure(
        DownloadFailureType.authRequired,
        'Требуется вход в Mail.ru.',
      );
    }
    if (session.email.trim().toLowerCase() != expectedEmail) {
      throw const DownloadCancelled();
    }
    return _authRepository.sessionEpoch;
  }

  @override
  Future<void> removeOffline(CloudNode node) async {
    if (_closed) throw StateError('DownloadRepository is closed.');
    if (node.type != CloudNodeType.file) {
      throw ArgumentError.value(
        node.type,
        'node.type',
        'Only files can be removed from offline storage.',
      );
    }
    final path = normalizeOfflineRemotePath(node.path);
    final operation = _TrackedRepositoryOperation();
    final cancellation = operation.cancellation;
    _activeOfflineRemovals.add(operation);
    void Function()? releasePath;

    try {
      final scope = _sessionForRemoval();
      _ensureRemovalSession(scope, cancellation);
      final cache = _cacheFactory(scope.session.email);
      // Keep the path lease across lookup, ownership removal, and filesystem
      // cleanup.  A stale remover must not delete a replacement published by
      // an editor or direct download after its initial lookup.
      releasePath = await _coordinator.acquire(
        cloudCachePathKey(cache.accountDirectoryName, path),
        cancellation,
        kind: CloudCacheLockKind.path,
      );
      try {
        final initialRecord = await _lookupOfflineRecord(
          scope,
          path: path,
          cancellation: cancellation,
        );
        if (initialRecord == null) return;
        var record = initialRecord;

        while (true) {
          _ensureRemovalSession(scope, cancellation);
          final release = await _coordinator.acquire(
            cloudCacheHashKey(
              cache.accountDirectoryName,
              normalizeCloudHash(record.hash),
            ),
            cancellation,
            kind: CloudCacheLockKind.hash,
          );
          try {
            _ensureRemovalSession(scope, cancellation);
            final current = await _lookupOfflineRecord(
              scope,
              path: path,
              cancellation: cancellation,
            );
            if (current == null) return;
            if (current.hash != record.hash) {
              // The binding changed while waiting for the hash lock. Acquire
              // the coordinator for the new object before mutating anything.
              record = current;
              continue;
            }

            _ensureRemovalSession(scope, cancellation);
            await _offlineFileIndex.remove(scope.session.email, path);
            _ensureRemovalSession(scope, cancellation);

            final hasReference = await _offlineFileIndex.hasHashReference(
              scope.session.email,
              current.hash,
            );
            _ensureRemovalSession(scope, cancellation);
            final hasTransientReference = await _hasTransientReference(
              scope.session.email,
              current.hash,
            );
            _ensureRemovalSession(scope, cancellation);
            if (!hasReference && !hasTransientReference) {
              _ensureRemovalSession(scope, cancellation);
              try {
                await _discardOfflineObject(cache, current.hash);
              } catch (_) {
                // Prefer the epoch/cancellation result when cleanup raced a
                // session change; otherwise preserve the safe disk failure.
                _ensureRemovalSession(scope, cancellation);
                rethrow;
              }
              _ensureRemovalSession(scope, cancellation);
            }
            return;
          } finally {
            release();
          }
        }
      } finally {
        releasePath();
        releasePath = null;
      }
    } finally {
      try {
        await cancellation.close();
      } finally {
        operation.complete();
        _activeOfflineRemovals.remove(operation);
      }
    }
  }

  /// Removes one recursive target and only unlinks CAS objects that have no
  /// remaining direct, ready-target, or transient reference in this account.
  /// Durable ownership is removed before filesystem cleanup; a disk failure
  /// therefore leaves the target's durable removing intent for an idempotent
  /// retry rather than claiming that the target was removed.
  @override
  Future<void> removeTarget(
    String targetPath, {
    required String expectedEmail,
    required String targetIncarnation,
  }) async {
    if (_closed) throw StateError('DownloadRepository is closed.');

    final operation = _TrackedRepositoryOperation();
    final cancellation = operation.cancellation;
    _activeTargetRemovals.add(operation);
    final pathReleases = <void Function()>[];
    final hashReleases = <void Function()>[];
    void Function()? releaseTarget;

    try {
      final normalizedEmail = _validateExpectedAccount(expectedEmail);
      final normalizedIncarnation = normalizeOfflineTargetIncarnation(
        targetIncarnation,
      );
      final scope = _sessionForRemoval(normalizedEmail);
      final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
      final cache = _cacheFactory(scope.session.email);
      _ensureRemovalSession(scope, cancellation);
      final targetRelease = await _targetCoordinator.acquire(
        _targetCoordinatorKey(cache, normalizedTargetPath),
        cancellation,
        kind: CloudCacheLockKind.target,
      );
      releaseTarget = targetRelease;

      final target = await _targetIndex.getTarget(
        scope.session.email,
        normalizedTargetPath,
        targetIncarnation: normalizedIncarnation,
      );
      _ensureRemovalSession(scope, cancellation);
      // A stale removal must not touch a newer target at the same path.
      if (target == null) return;

      final files = await _targetIndex.listTargetFiles(
        scope.session.email,
        normalizedTargetPath,
        targetIncarnation: normalizedIncarnation,
      );
      _ensureRemovalSession(scope, cancellation);
      final hashes = <String>{
        for (final file in files)
          if (file.hasValidHash) file.hash!,
      }.toList()..sort();

      // The target lock is held for the whole logical operation. Acquire all
      // affected path locks in deterministic order, then all hash locks. This
      // is the same target -> path -> hash order used by target downloads and
      // editor ownership hand-offs.
      final paths = files.map((file) => file.filePath).toSet().toList()..sort();
      for (final path in paths) {
        _ensureRemovalSession(scope, cancellation);
        pathReleases.add(
          await _coordinator.acquire(
            cloudCachePathKey(cache.accountDirectoryName, path),
            cancellation,
            kind: CloudCacheLockKind.path,
          ),
        );
      }
      for (final hash in hashes) {
        _ensureRemovalSession(scope, cancellation);
        hashReleases.add(
          await _coordinator.acquire(
            cloudCacheHashKey(cache.accountDirectoryName, hash),
            cancellation,
            kind: CloudCacheLockKind.hash,
          ),
        );
      }

      _ensureRemovalSession(scope, cancellation);
      // Re-read ownership after taking the object locks. A conforming target
      // operation cannot change this list while the target lock is held, and
      // this read closes the snapshot/lock boundary for implementations that
      // use a separate SQLite executor.
      final lockedFiles = await _targetIndex.listTargetFiles(
        scope.session.email,
        normalizedTargetPath,
        targetIncarnation: normalizedIncarnation,
      );
      _ensureRemovalSession(scope, cancellation);
      final lockedHashes = <String>{
        for (final file in lockedFiles)
          if (file.hasValidHash) file.hash!,
      };
      if (!lockedHashes.every(hashes.contains)) {
        throw const DownloadCancelled(
          'Target ownership changed while removal was being prepared.',
        );
      }

      for (final hash in hashes) {
        _ensureRemovalSession(scope, cancellation);
        final hasReference = await _targetIndex.hasHashReferenceOutsideTarget(
          scope.session.email,
          hash,
          targetPath: normalizedTargetPath,
          targetIncarnation: normalizedIncarnation,
        );
        _ensureRemovalSession(scope, cancellation);
        final hasTransient = await _hasTransientReference(
          scope.session.email,
          hash,
        );
        _ensureRemovalSession(scope, cancellation);
        if (!hasReference && !hasTransient) {
          await _discardOfflineObject(cache, hash);
          _ensureRemovalSession(scope, cancellation);
        }
      }

      // Delete durable ownership only after every required filesystem delete
      // succeeded. If one delete fails, the row remains removing and the next
      // idempotent retry sees the same hashes.
      await _targetIndex.removeTarget(
        scope.session.email,
        normalizedTargetPath,
        targetIncarnation: normalizedIncarnation,
      );
    } finally {
      for (final release in hashReleases.reversed) {
        release();
      }
      for (final release in pathReleases.reversed) {
        release();
      }
      releaseTarget?.call();
      try {
        await cancellation.close();
      } finally {
        operation.complete();
        _activeTargetRemovals.remove(operation);
      }
    }
  }

  /// Removes only unowned, canonical final objects from one account.
  ///
  /// Candidates are processed in hash order. A reference-query or filesystem
  /// failure leaves that candidate untouched, is collected, and does not stop
  /// later candidates from being reconciled; the call reports one typed disk
  /// failure after the deterministic pass. A failure while enumerating the
  /// tree aborts before any deletion. Missing objects are harmless.
  @override
  Future<void> reconcileAccountCache({required String expectedEmail}) async {
    if (_closed) throw StateError('DownloadRepository is closed.');
    final normalizedEmail = _validateExpectedAccount(expectedEmail);
    final session = _authRepository.currentSession;
    if (session == null) {
      throw const DownloadFailure(
        DownloadFailureType.authRequired,
        'Требуется вход в Mail.ru.',
      );
    }
    if (session.email.trim().toLowerCase() != normalizedEmail) {
      throw const DownloadCancelled();
    }

    final scope = _DownloadSessionScope(
      session: session,
      epoch: _authRepository.sessionEpoch,
    );
    final operation = _TrackedRepositoryOperation();
    _activeReconciliations.add(operation);
    try {
      await _runReconciliation(
        scope,
        normalizedEmail: normalizedEmail,
        operation: operation,
      );
    } finally {
      try {
        await operation.cancellation.close();
      } finally {
        operation.complete();
        _activeReconciliations.remove(operation);
      }
    }
  }

  Future<void> _runReconciliation(
    _DownloadSessionScope scope, {
    required String normalizedEmail,
    required _TrackedRepositoryOperation operation,
  }) async {
    StreamSubscription<CloudSession?>? sessionSubscription;
    try {
      sessionSubscription = _authRepository.sessionChanges.listen((_) {
        if (!_isCurrentSession(scope)) operation.cancel();
      });

      _ensureReconciliationSession(scope, operation.cancellation);
      final cache = _cacheFactory(scope.session.email);
      final expectedAccountKey = accountCacheKey(normalizedEmail);
      if (cache.accountDirectoryName != expectedAccountKey) {
        throw const DownloadFailure(
          DownloadFailureType.service,
          'Офлайн-кэш недоступен для текущего аккаунта.',
        );
      }

      final releaseAccount = await _reconciliationCoordinator.acquire(
        cloudCacheAccountKey(expectedAccountKey),
        operation.cancellation,
        kind: CloudCacheLockKind.account,
      );
      try {
        _ensureReconciliationSession(scope, operation.cancellation);
        late final List<CacheObjectCandidate> candidates;
        try {
          candidates = await cache.enumerateFinalObjects();
        } catch (_) {
          _ensureReconciliationSession(scope, operation.cancellation);
          throw DownloadFailure(
            DownloadFailureType.disk,
            'Не удалось просмотреть офлайн-кэш.',
          );
        }
        _ensureReconciliationSession(scope, operation.cancellation);

        var failureCount = 0;
        for (final candidate in candidates) {
          _ensureReconciliationSession(scope, operation.cancellation);
          final releaseHash = await _coordinator.acquire(
            cloudCacheHashKey(cache.accountDirectoryName, candidate.hash),
            operation.cancellation,
            kind: CloudCacheLockKind.hash,
          );
          try {
            await _reconcileCandidate(
              scope,
              cache: cache,
              candidate: candidate,
              cancellation: operation.cancellation,
            );
          } on DownloadCancelled {
            rethrow;
          } catch (_) {
            _ensureReconciliationSession(scope, operation.cancellation);
            failureCount += 1;
          } finally {
            releaseHash();
          }
        }

        _ensureReconciliationSession(scope, operation.cancellation);
        if (failureCount > 0) {
          throw DownloadFailure(
            DownloadFailureType.disk,
            'Не удалось полностью очистить офлайн-кэш.',
          );
        }
      } finally {
        releaseAccount();
      }
    } finally {
      await sessionSubscription?.cancel();
    }
  }

  Future<void> _reconcileCandidate(
    _DownloadSessionScope scope, {
    required ContentAddressedFileCache cache,
    required CacheObjectCandidate candidate,
    required DownloadCancellationToken cancellation,
  }) async {
    _ensureReconciliationSession(scope, cancellation);
    if (!await cache.isCanonicalFinalObject(candidate)) return;
    _ensureReconciliationSession(scope, cancellation);

    final referenceFailures = <Object>[];
    var hasDurableReference = false;
    try {
      hasDurableReference = await _offlineFileIndex.hasHashReference(
        scope.session.email,
        candidate.hash,
      );
      _ensureReconciliationSession(scope, cancellation);
    } catch (error) {
      _ensureReconciliationSession(scope, cancellation);
      referenceFailures.add(error);
    }

    var hasTransientReference = false;
    final transientIndex = _transientObjectIndex;
    if (transientIndex == null) {
      // Without the transient index there is no safe way to prove that an
      // external-open reference is absent, so fail closed and keep the file.
      referenceFailures.add(
        StateError('Transient object ownership is unavailable.'),
      );
    } else {
      try {
        hasTransientReference = await transientIndex.hasTransientReference(
          scope.session.email,
          candidate.hash,
        );
        _ensureReconciliationSession(scope, cancellation);
      } catch (error) {
        _ensureReconciliationSession(scope, cancellation);
        referenceFailures.add(error);
      }
    }

    if (referenceFailures.isNotEmpty) {
      throw _ReconciliationReferenceFailure(referenceFailures);
    }
    if (hasDurableReference || hasTransientReference) return;

    _ensureReconciliationSession(scope, cancellation);
    if (!await cache.isCanonicalFinalObject(candidate)) return;
    _ensureReconciliationSession(scope, cancellation);
    try {
      await candidate.file.delete();
    } on FileSystemException {
      // A concurrent operation may have committed or removed this object
      // between the final type check and unlink. Missing is an idempotent
      // success; every other filesystem failure is retained for retry.
      final type = await FileSystemEntity.type(
        candidate.file.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return;
      rethrow;
    }
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;

    _closed = true;
    _openGeneration++;
    _protectedOpen = null;
    final activeOperations = <Future<void>>[
      ..._active.map((operation) => operation.completion),
      ..._activeOfflineRemovals.map((operation) => operation.completion),
      ..._activeTargetRemovals.map((operation) => operation.completion),
      ..._activeReconciliations.map((operation) => operation.completion),
    ];
    for (final operation in _activeReconciliations.toList(growable: false)) {
      operation.cancel();
    }
    for (final operation in _activeOfflineRemovals.toList(growable: false)) {
      operation.cancel();
    }
    for (final operation in _activeTargetRemovals.toList(growable: false)) {
      operation.cancel();
    }
    for (final operation in _active.toList(growable: false)) {
      operation.cancel();
    }
    final closing = _finishClose(activeOperations);
    _closeFuture = closing;
    return closing;
  }

  Future<void> _finishClose(List<Future<void>> activeOperations) async {
    // Cancellation only makes the operations leave their transport/lock wait;
    // the transport must remain usable until every persistence cleanup has
    // settled. This also lets a close racing a coordinator waiter finish
    // without holding a lock that shutdown needs.
    await Future.wait(activeOperations, eagerError: false);
    _transport.close();
  }

  Future<bool> _hasTransientReference(String email, String hash) async {
    final index = _transientObjectIndex;
    if (index == null) return false;
    return index.hasTransientReference(email, hash);
  }

  Future<void> _touchTransient(
    _DownloadSessionScope scope,
    _DownloadMetadata metadata,
    DownloadCancellationToken cancellation, {
    required int generation,
  }) async {
    final index = _transientObjectIndex;
    cancellation.throwIfCancelled();
    _ensureSession(scope);
    if (index != null) {
      await index.touchTransient(
        scope.session.email,
        TransientObjectRecord(
          hash: metadata.hash,
          size: metadata.size,
          lastAccessedAt: DateTime.now().toUtc(),
        ),
      );
    }
    cancellation.throwIfCancelled();
    _ensureSession(scope);
    if (!_closed && generation == _openGeneration) {
      final account = _TransientAccount(
        email: scope.session.email,
        accountKey: _cacheFactory(scope.session.email).accountDirectoryName,
      );
      _protectedOpen = _ProtectedOpen(
        account: account,
        generation: generation,
        hash: metadata.hash,
      );
    }
  }

  Future<void> _finishOpen(
    _DownloadSessionScope scope,
    _DownloadMetadata metadata,
    DownloadCancellationToken cancellation, {
    required int generation,
    required _ProtectedOpen? releasedProtection,
  }) async {
    cancellation.throwIfCancelled();
    _ensureSession(scope);
    if (_closed || generation != _openGeneration) return;

    final current = _TransientAccount(
      email: scope.session.email,
      accountKey: _cacheFactory(scope.session.email).accountDirectoryName,
    );
    final protection = _ProtectedOpen(
      account: current,
      generation: generation,
      hash: metadata.hash,
    );
    _protectedOpen = protection;
    try {
      final accounts = <_TransientAccount>[current];
      if (releasedProtection != null &&
          releasedProtection.accountKey != current.accountKey) {
        accounts.add(releasedProtection.account);
      }
      for (final account in accounts) {
        cancellation.throwIfCancelled();
        await _pruneAccount(account, cancellation);
      }
    } catch (_) {
      if (identical(_protectedOpen, protection)) _protectedOpen = null;
      rethrow;
    }
  }

  void _discardOpenProtection(int generation) {
    final protection = _protectedOpen;
    if (protection != null && protection.generation == generation) {
      _protectedOpen = null;
    }
  }

  Future<void> _pruneAccount(
    _TransientAccount account,
    DownloadCancellationToken cancellation,
  ) async {
    final index = _transientObjectIndex;
    if (index == null) return;
    final release = await _pruneCoordinator.acquire(
      cloudCacheAccountKey(account.accountKey),
      cancellation,
      kind: CloudCacheLockKind.account,
    );
    try {
      cancellation.throwIfCancelled();
      if (_closed) throw const DownloadCancelled();
      final cache = _cacheFactory(account.email);
      if (cache.accountDirectoryName != account.accountKey) {
        throw StateError('Transient cache account identity changed.');
      }

      final records = await index.listTransient(account.email);
      cancellation.throwIfCancelled();
      var total = 0;
      final candidates = <TransientObjectRecord>[];
      for (final record in records) {
        cancellation.throwIfCancelled();
        if (await _offlineFileIndex.hasHashReference(
          account.email,
          record.hash,
        )) {
          continue;
        }
        total += record.size;
        candidates.add(record);
      }
      for (final candidate in candidates) {
        cancellation.throwIfCancelled();

        final releaseHash = await _coordinator.acquire(
          cloudCacheHashKey(cache.accountDirectoryName, candidate.hash),
          cancellation,
          kind: CloudCacheLockKind.hash,
        );
        try {
          cancellation.throwIfCancelled();
          if (_closed || cache.accountDirectoryName != account.accountKey) {
            throw const DownloadCancelled();
          }

          final current = await _findTransient(
            index,
            account.email,
            candidate.hash,
          );
          if (current == null) {
            total -= candidate.size;
            continue;
          }
          total += current.size - candidate.size;
          cancellation.throwIfCancelled();
          if (await _offlineFileIndex.hasHashReference(
            account.email,
            current.hash,
          )) {
            total -= current.size;
            continue;
          }

          final object = await cache.objectFile(current.hash);
          final objectState = await _transientObjectState(object);
          if (objectState == _TransientObjectState.missing) {
            // A crash can leave a durable reference without its final object.
            // It is safe to discard that row, including while its hash is the
            // in-memory protected hash, because there is nothing to protect.
            cancellation.throwIfCancelled();
            await index.removeTransient(account.email, current.hash);
            total -= current.size;
            continue;
          }
          if (objectState != _TransientObjectState.file) continue;
          if (total <= _transientCacheCapBytes ||
              _isProtected(account.accountKey, current.hash)) {
            continue;
          }

          try {
            await object.delete();
          } on FileSystemException {
            // Keep the row so a later successful open can retry deletion.
            continue;
          }
          cancellation.throwIfCancelled();
          await index.removeTransient(account.email, current.hash);
          total -= current.size;
        } finally {
          releaseHash();
        }
      }
    } finally {
      release();
    }
  }

  Future<TransientObjectRecord?> _findTransient(
    TransientObjectIndex index,
    String email,
    String hash,
  ) async {
    final normalizedHash = normalizeCloudHash(hash);
    final records = await index.listTransient(email);
    for (final record in records) {
      if (record.hash == normalizedHash) return record;
    }
    return null;
  }

  Future<_TransientObjectState> _transientObjectState(File object) async {
    try {
      final type = await FileSystemEntity.type(object.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return _TransientObjectState.missing;
      }
      if (type == FileSystemEntityType.file) {
        return _TransientObjectState.file;
      }
      return _TransientObjectState.other;
    } on FileSystemException {
      // Treat an unreadable object like a failed eviction. The durable row is
      // retained so a later prune can retry it.
      return _TransientObjectState.other;
    }
  }

  bool _isProtected(String accountKey, String hash) {
    final protectedOpen = _protectedOpen;
    return protectedOpen != null &&
        protectedOpen.accountKey == accountKey &&
        protectedOpen.hash == normalizeCloudHash(hash);
  }

  String _targetCoordinatorKey(
    ContentAddressedFileCache cache,
    String targetPath,
  ) => cloudCacheTargetKey(cache.accountDirectoryName, targetPath);

  _DownloadSessionScope _sessionForRemoval([String? expectedEmail]) {
    final session = _authRepository.currentSession;
    if (session == null) {
      throw const DownloadFailure(
        DownloadFailureType.authRequired,
        'Требуется вход в Mail.ru.',
      );
    }
    if (expectedEmail != null &&
        session.email.trim().toLowerCase() != expectedEmail) {
      throw const DownloadCancelled();
    }
    return _DownloadSessionScope(
      session: session,
      epoch: _authRepository.sessionEpoch,
    );
  }

  _DownloadSessionScope? _captureSessionScope() {
    final session = _authRepository.currentSession;
    if (session == null) return null;
    return _DownloadSessionScope(
      session: session,
      epoch: _authRepository.sessionEpoch,
    );
  }

  Future<OfflineFileRecord?> _lookupOfflineRecord(
    _DownloadSessionScope scope, {
    required String path,
    required DownloadCancellationToken cancellation,
  }) async {
    final records = await _offlineFileIndex.lookup(scope.session.email, [path]);
    _ensureRemovalSession(scope, cancellation);
    return records[path];
  }

  void _ensureRemovalSession(
    _DownloadSessionScope scope,
    DownloadCancellationToken cancellation,
  ) {
    cancellation.throwIfCancelled();
    if (_closed) throw const DownloadCancelled();
    _ensureSession(scope);
  }

  void _ensureReconciliationSession(
    _DownloadSessionScope scope,
    DownloadCancellationToken cancellation,
  ) {
    cancellation.throwIfCancelled();
    if (_closed) throw const DownloadCancelled();
    _ensureSession(scope);
  }

  bool _isCurrentSession(_DownloadSessionScope scope) {
    final current = _authRepository.currentSession;
    return _authRepository.sessionEpoch == scope.epoch &&
        current != null &&
        current.email.trim().toLowerCase() ==
            scope.session.email.trim().toLowerCase();
  }

  void _ensureSession(_DownloadSessionScope scope) {
    final current = _authRepository.currentSession;
    if (_authRepository.sessionEpoch != scope.epoch ||
        current == null ||
        current.email.trim().toLowerCase() !=
            scope.session.email.trim().toLowerCase()) {
      throw const DownloadCancelled();
    }
  }

  Future<void> _discardOfflineObject(
    ContentAddressedFileCache cache,
    String hash,
  ) async {
    try {
      final object = await cache.objectFile(hash);
      final type = await FileSystemEntity.type(object.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw FileSystemException(
          'Cache object path is not a file.',
          object.path,
        );
      }
      await cache.discardObject(hash);
    } catch (_) {
      // Do not leak cache paths or filesystem details through the public API.
      // The binding was already removed and must not be recreated here.
      throw const DownloadFailure(
        DownloadFailureType.disk,
        'Не удалось удалить файл из офлайн-кэша.',
      );
    }
  }
}

final class _DownloadOperation {
  _DownloadOperation({
    required this.node,
    required this.mode,
    required this.targetPath,
    required this.expectedTargetEmail,
    required this.expectedTargetIncarnation,
    required this.expectedTargetSessionEpoch,
    required this.openScope,
    required this.api,
    required this.transport,
    required this.authRepository,
    required this.offlineFileIndex,
    required this.targetIndex,
    required this.cacheFactory,
    required this.coordinator,
    required this.targetCoordinator,
    required this.onOpenVerified,
    required this.onOpenPrepared,
    required this.onFinished,
  }) {
    handle = _DownloadHandle(
      progress: _progress.stream,
      result: _result.future,
      onCancel: _cancel,
    );
  }

  final CloudNode node;
  final _DownloadMode mode;
  final String? targetPath;
  final String? expectedTargetEmail;
  final String? expectedTargetIncarnation;
  final int? expectedTargetSessionEpoch;
  final _DownloadSessionScope? openScope;
  final CloudMailApi api;
  final DownloadTransport transport;
  final AuthRepository authRepository;
  final OfflineFileIndex offlineFileIndex;
  final OfflineTargetIndex targetIndex;
  final DownloadCacheFactory cacheFactory;
  final CloudCacheCoordinator coordinator;
  final CloudCacheCoordinator targetCoordinator;
  final Future<void> Function(
    _DownloadSessionScope,
    _DownloadMetadata,
    DownloadCancellationToken,
  )?
  onOpenVerified;
  final Future<void> Function(
    _DownloadSessionScope,
    _DownloadMetadata,
    DownloadCancellationToken,
  )?
  onOpenPrepared;
  final void Function(bool succeeded) onFinished;
  final DownloadCancellationToken cancellation = DownloadCancellationToken();
  final _progress = StreamController<DownloadProgress>.broadcast(sync: true);
  final _result = Completer<File>();
  final _completion = Completer<void>();
  CloudNode? _verifiedNode;

  late final DownloadHandle handle;
  StreamSubscription<CloudSession?>? _sessionSubscription;
  bool _finished = false;

  Future<void> get completion => _completion.future;

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
    var succeeded = false;
    try {
      final scope = mode == _DownloadMode.open
          ? _requireCapturedOpenSession()
          : mode == _DownloadMode.target
          ? await _requireTargetSession()
          : await _requireSession();
      cancellation.throwIfCancelled();
      _observeSession(scope);
      _emit(
        const DownloadProgress(
          phase: DownloadPhase.resolving,
          bytes: 0,
          total: null,
          resumed: false,
        ),
      );

      switch (mode) {
        case _DownloadMode.open:
          await _runOpen(scope);
        case _DownloadMode.direct:
          await _runDirect(scope);
        case _DownloadMode.target:
          await _runTarget(scope);
      }
      succeeded = true;
    } catch (error, stackTrace) {
      final failure = cancellation.isCancelled && error is! DownloadCancelled
          ? const DownloadCancelled()
          : error;
      _fail(failure, stackTrace);
    } finally {
      _finished = true;
      try {
        await _sessionSubscription?.cancel();
      } catch (_) {
        // Session stream cleanup must not replace the typed operation result.
      }
      _sessionSubscription = null;
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
      try {
        onFinished(succeeded);
      } catch (_) {
        // Lifecycle bookkeeping must not turn the unawaited worker future
        // into an unhandled error during shutdown.
      } finally {
        if (!_completion.isCompleted) _completion.complete();
      }
    }
  }

  _DownloadSessionScope _requireCapturedOpenSession() {
    final scope = openScope;
    if (scope == null) {
      throw const DownloadFailure(
        DownloadFailureType.authRequired,
        'Требуется вход в Mail.ru.',
      );
    }
    _ensureSession(scope);
    return scope;
  }

  void _observeSession(_DownloadSessionScope scope) {
    _sessionSubscription = authRepository.sessionChanges.listen((_) {
      if (!_isCurrentSession(scope)) cancellation.cancel();
    });
  }

  Future<void> _runOpen(_DownloadSessionScope scope) async {
    final path = normalizeOfflineRemotePath(node.path);
    final direct = await _lookupOpenRecord(scope, path);
    if (direct != null && _matchesDirectRecord(node, direct)) {
      final cache = cacheFactory(scope.session.email);
      // A direct binding may need repair, so serialize its entire open path
      // with editor save, direct download, and removeOffline. Re-read after
      // taking the lease because the initial lookup was only a hint.
      final releasePath = await coordinator.acquire(
        cloudCachePathKey(cache.accountDirectoryName, path),
        cancellation,
        kind: CloudCacheLockKind.path,
      );
      _MetadataRunResult? prepared;
      try {
        _ensureOperationSession(scope);
        final current = await _lookupOpenRecord(scope, path);
        if (current != null &&
            current.hash == direct.hash &&
            _matchesDirectRecord(node, current)) {
          prepared = await _runWithMetadata(
            scope,
            cacheOverride: cache,
            remoteNode: _nodeForBinding(current),
            metadata: _metadataForRecord(current),
            existingBinding: current,
          );
        }
      } finally {
        releasePath();
      }
      if (prepared != null) {
        await onOpenPrepared!(scope, prepared.metadata, cancellation);
        _ensureOperationSession(scope);
        _succeed(prepared.file);
        return;
      }
    }

    final targetMembership = await targetIndex.lookupReadyTargetFile(
      scope.session.email,
      path,
    );
    _ensureOperationSession(scope);
    if (targetMembership != null) {
      await _runInheritedOpen(scope, targetMembership);
      return;
    }

    final freshNode = await _statAndValidate(scope, node.path);
    final metadata = _validatedMetadata(freshNode);
    final prepared = await _runWithMetadata(
      scope,
      remoteNode: freshNode,
      metadata: metadata,
      existingBinding: null,
    );
    await onOpenPrepared!(scope, prepared.metadata, cancellation);
    _ensureOperationSession(scope);
    _succeed(prepared.file);
  }

  Future<void> _runDirect(_DownloadSessionScope scope) async {
    final path = _canonicalPathOrNull(node.path);
    if (path == null) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Путь удалённого файла недействителен.',
      );
    }
    final cache = cacheFactory(scope.session.email);
    // Direct downloads can replace the binding at the end of the operation.
    // Hold the path lease from fresh stat through cache commit and index
    // publication so a stale operation cannot overwrite an editor result.
    final releasePath = await coordinator.acquire(
      cloudCachePathKey(cache.accountDirectoryName, path),
      cancellation,
      kind: CloudCacheLockKind.path,
    );
    try {
      _ensureOperationSession(scope);
      final freshNode = await _statAndValidate(scope, node.path);
      final metadata = _validatedMetadata(freshNode);
      final prepared = await _runWithMetadata(
        scope,
        cacheOverride: cache,
        remoteNode: freshNode,
        metadata: metadata,
        existingBinding: null,
      );
      _ensureOperationSession(scope);
      _succeed(prepared.file);
    } finally {
      releasePath();
    }
  }

  Future<void> _runInheritedOpen(
    _DownloadSessionScope scope,
    OfflineTargetFileRecord selected,
  ) async {
    final cache = cacheFactory(scope.session.email);
    final release = await targetCoordinator.acquire(
      cloudCacheTargetKey(cache.accountDirectoryName, selected.targetPath),
      cancellation,
      kind: CloudCacheLockKind.target,
    );
    late final _MetadataRunResult prepared;
    try {
      _ensureOperationSession(scope);
      final current = await targetIndex.getTargetFile(
        scope.session.email,
        selected.targetPath,
        selected.filePath,
        targetIncarnation: selected.targetIncarnation,
      );
      _ensureOperationSession(scope);
      if (current == null ||
          current.targetIncarnation != selected.targetIncarnation ||
          current.readiness != OfflineReadiness.ready ||
          !_hasCompleteTargetMetadata(current)) {
        // The membership that selected this path was removed, re-enqueued, or
        // made non-ready while the open was waiting for the target lock. Do
        // not fall back to a remote download: that could return an object from
        // a deleted incarnation.
        throw const DownloadCancelled();
      }

      final metadata = _metadataForTargetMembership(current);
      // Keep the path lease even for a cache hit: the object can become
      // corrupt between a preliminary check and the actual read/repair.
      final releasePath = await coordinator.acquire(
        cloudCachePathKey(cache.accountDirectoryName, current.filePath),
        cancellation,
        kind: CloudCacheLockKind.path,
      );
      try {
        prepared = await _runWithMetadata(
          scope,
          cacheOverride: cache,
          remoteNode: _nodeForTargetMembership(current),
          metadata: metadata,
          existingBinding: null,
          openTargetMembership: current,
          repairOpenTargetMembership: false,
          onCacheMiss: () async {
            // A target membership is an offline hint only. If its CAS object is
            // absent or corrupt, obtain fresh metadata before repairing the
            // membership through target ownership semantics.
            final freshNode = await _statAndValidate(scope, node.path);
            return _DownloadMetadataResolution(
              remoteNode: freshNode,
              metadata: _validatedMetadata(freshNode),
            );
          },
        );
      } finally {
        releasePath();
      }
    } finally {
      release();
    }
    await onOpenPrepared!(scope, prepared.metadata, cancellation);
    _ensureOperationSession(scope);
    _succeed(prepared.file);
  }

  Future<void> _runTarget(_DownloadSessionScope scope) async {
    final target = targetPath;
    final expectedEmail = expectedTargetEmail;
    final expectedIncarnation = expectedTargetIncarnation;
    if (target == null ||
        expectedEmail == null ||
        expectedIncarnation == null) {
      throw const DownloadFailure(
        DownloadFailureType.service,
        'Загрузка в офлайн-цель недоступна.',
      );
    }
    if (scope.session.email.trim().toLowerCase() != expectedEmail) {
      throw const DownloadCancelled();
    }
    final cache = cacheFactory(scope.session.email);
    final release = await targetCoordinator.acquire(
      cloudCacheTargetKey(cache.accountDirectoryName, target),
      cancellation,
      kind: CloudCacheLockKind.target,
    );
    late final _MetadataRunResult prepared;
    try {
      _ensureOperationSession(scope);
      final currentTarget = await targetIndex.getTarget(
        scope.session.email,
        target,
        targetIncarnation: expectedIncarnation,
      );
      _ensureOperationSession(scope);
      if (currentTarget == null ||
          currentTarget.state == OfflineTargetState.removing) {
        throw const DownloadCancelled();
      }

      final requestedPath = _canonicalPathOrNull(node.path);
      if (requestedPath == null) {
        throw const DownloadFailure(
          DownloadFailureType.invalidResponse,
          'Путь удалённого файла недействителен.',
        );
      }
      // Target operations acquire target -> path -> hash. Holding the path
      // lease through stat, CAS commit, and membership publication prevents a
      // concurrent editor or removal from observing a half hand-off.
      final releasePath = await coordinator.acquire(
        cloudCachePathKey(cache.accountDirectoryName, requestedPath),
        cancellation,
        kind: CloudCacheLockKind.path,
      );
      try {
        final freshNode = await _statAndValidate(scope, node.path);
        final freshPath = _canonicalPathOrNull(freshNode.path);
        if (freshPath == null || !_isFileUnderTarget(target, freshPath)) {
          throw const DownloadFailure(
            DownloadFailureType.invalidResponse,
            'Файл не принадлежит указанной офлайн-цели.',
          );
        }
        final metadata = _validatedMetadata(freshNode);
        final membership = await targetIndex.getTargetFile(
          scope.session.email,
          target,
          freshPath,
          targetIncarnation: expectedIncarnation,
        );
        _ensureOperationSession(scope);
        if (membership == null ||
            membership.targetPath != target ||
            membership.targetIncarnation != expectedIncarnation ||
            membership.filePath != freshPath) {
          throw const DownloadCancelled();
        }

        prepared = await _runWithMetadata(
          scope,
          cacheOverride: cache,
          remoteNode: freshNode,
          metadata: metadata,
          existingBinding: null,
          targetMembership: membership,
        );
      } finally {
        releasePath();
      }
    } finally {
      release();
    }
    _ensureOperationSession(scope);
    _succeed(prepared.file);
  }

  Future<OfflineFileRecord?> _lookupOpenRecord(
    _DownloadSessionScope scope,
    String path,
  ) async {
    final records = await offlineFileIndex.lookup(scope.session.email, [path]);
    _ensureOperationSession(scope);
    return records[path];
  }

  bool _matchesDirectRecord(CloudNode candidate, OfflineFileRecord record) {
    if (candidate.type != CloudNodeType.file) return false;
    final path = _canonicalPathOrNull(candidate.path);
    if (path == null || path != record.path) return false;

    final size = candidate.size;
    if (size != null && (size < 0 || size != record.size)) return false;

    final hash = candidate.hash;
    if (hash != null) {
      final normalizedHash = hash.trim().toUpperCase();
      if (normalizedHash != record.hash ||
          !RegExp(r'^[0-9A-F]{40}$').hasMatch(normalizedHash)) {
        return false;
      }
    }
    return true;
  }

  CloudNode _nodeForBinding(OfflineFileRecord record) {
    final name = node.name.trim().isEmpty ? record.name : node.name;
    return CloudNode(
      path: record.path,
      name: name,
      type: CloudNodeType.file,
      size: node.size ?? record.size,
      modifiedAt: node.modifiedAt ?? record.modifiedAt,
      hash: node.hash ?? record.hash,
      revision: node.revision ?? record.revision,
      globalRevision: node.globalRevision ?? record.globalRevision,
    );
  }

  _DownloadMetadata _metadataForRecord(OfflineFileRecord record) =>
      _DownloadMetadata(size: record.size, hash: record.hash);

  _DownloadMetadata _metadataForTargetMembership(
    OfflineTargetFileRecord membership,
  ) => _DownloadMetadata(size: membership.size!, hash: membership.hash!);

  CloudNode _nodeForTargetMembership(OfflineTargetFileRecord membership) =>
      CloudNode(
        path: membership.filePath,
        name: membership.name,
        type: CloudNodeType.file,
        size: membership.size,
        modifiedAt: membership.modifiedAt,
        hash: membership.hash,
        revision: membership.revision,
        globalRevision: membership.globalRevision,
      );

  bool _hasCompleteTargetMetadata(OfflineTargetFileRecord membership) {
    final size = membership.size;
    final hash = membership.hash;
    if (size == null || size < 0 || hash == null) return false;
    try {
      normalizeCloudHash(hash);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  Future<CloudNode> _statAndValidate(
    _DownloadSessionScope scope,
    String path,
  ) async {
    cancellation.throwIfCancelled();
    _ensureSession(scope);
    final freshNode = await _stat(path);
    cancellation.throwIfCancelled();
    _ensureSession(scope);
    final requestedPath = _canonicalPathOrNull(path);
    final returnedPath = _canonicalPathOrNull(freshNode.path);
    if (requestedPath == null ||
        returnedPath == null ||
        returnedPath != requestedPath) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Mail.ru вернул метаданные другого файла.',
      );
    }
    return freshNode;
  }

  Future<_MetadataRunResult> _runWithMetadata(
    _DownloadSessionScope scope, {
    ContentAddressedFileCache? cacheOverride,
    required CloudNode remoteNode,
    required _DownloadMetadata metadata,
    OfflineFileRecord? existingBinding,
    OfflineTargetFileRecord? targetMembership,
    OfflineTargetFileRecord? openTargetMembership,
    bool repairOpenTargetMembership = false,
    Future<_DownloadMetadataResolution> Function()? onCacheMiss,
  }) async {
    final cache = cacheOverride ?? cacheFactory(scope.session.email);
    var currentRemoteNode = remoteNode;
    var currentMetadata = metadata;
    var currentRepairOpenTargetMembership = repairOpenTargetMembership;
    var resolveCacheMiss = onCacheMiss;
    late final File object;
    while (true) {
      final release = await coordinator.acquire(
        cloudCacheHashKey(cache.accountDirectoryName, currentMetadata.hash),
        cancellation,
        kind: CloudCacheLockKind.hash,
      );
      late final _MetadataAttempt attempt;
      try {
        attempt = await _runWithMetadataUnderLock(
          scope,
          cache: cache,
          remoteNode: currentRemoteNode,
          metadata: currentMetadata,
          existingBinding: existingBinding,
          targetMembership: targetMembership,
          openTargetMembership: openTargetMembership,
          repairOpenTargetMembership: currentRepairOpenTargetMembership,
          onCacheMiss: resolveCacheMiss,
        );
      } finally {
        release();
      }

      switch (attempt) {
        case _MetadataSuccess(:final file):
          object = file;
        case _MetadataRetry(:final resolution):
          currentRemoteNode = resolution.remoteNode;
          currentMetadata = resolution.metadata;
          currentRepairOpenTargetMembership =
              openTargetMembership != null || currentRepairOpenTargetMembership;
          resolveCacheMiss = null;
          continue;
      }
      break;
    }
    _verifiedNode = currentRemoteNode;
    _ensureOperationSession(scope);
    return _MetadataRunResult(file: object, metadata: currentMetadata);
  }

  Future<_MetadataAttempt> _runWithMetadataUnderLock(
    _DownloadSessionScope scope, {
    required ContentAddressedFileCache cache,
    required CloudNode remoteNode,
    required _DownloadMetadata metadata,
    OfflineFileRecord? existingBinding,
    OfflineTargetFileRecord? targetMembership,
    OfflineTargetFileRecord? openTargetMembership,
    required bool repairOpenTargetMembership,
    Future<_DownloadMetadataResolution> Function()? onCacheMiss,
  }) async {
    _ensureOperationSession(scope);
    final cached = await cache.lookup(
      metadata.hash,
      expectedSize: metadata.size,
    );
    cancellation.throwIfCancelled();
    _ensureSession(scope);
    if (cached != null) {
      final cachedHash = await calculateCloudFileHash(cached);
      cancellation.throwIfCancelled();
      _ensureSession(scope);
      if (_sameHash(cachedHash, metadata.hash)) {
        await _publishVerifiedOwnership(
          scope,
          remoteNode: remoteNode,
          metadata: metadata,
          existingBinding: existingBinding,
          targetMembership: targetMembership,
          openTargetMembership: openTargetMembership,
          repairOpenTargetMembership: repairOpenTargetMembership,
        );
        _ensureOperationSession(scope);
        _emit(
          DownloadProgress(
            phase: DownloadPhase.committed,
            bytes: metadata.size,
            total: metadata.size,
            resumed: false,
            cacheHit: true,
          ),
        );
        _ensureOperationSession(scope);
        return _MetadataSuccess(cached);
      }
      _ensureOperationSession(scope);
      await cache.discardObject(metadata.hash);
    } else {
      // A size mismatch is also a stale object. Removing it here is needed
      // because ContentAddressedFileCache.commit preserves existing objects.
      _ensureOperationSession(scope);
      await cache.discardObject(metadata.hash);
    }

    final resolve = onCacheMiss;
    if (resolve != null) {
      final resolution = await resolve();
      return _MetadataRetry(resolution);
    }

    _ensureOperationSession(scope);
    final partFile = await cache.partFile(metadata.hash);
    _ensureOperationSession(scope);
    final request = DownloadRequest(
      remotePath: remoteNode.path,
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
    _ensureSession(scope);
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
    _ensureSession(scope);
    if (!_sameHash(actualHash, metadata.hash)) {
      await _deleteQuietly(partFile);
      throw DownloadIntegrityFailure(
        'Хеш загруженного файла не совпадает с метаданными.',
        expectedHash: metadata.hash,
        actualHash: actualHash,
      );
    }

    cancellation.throwIfCancelled();
    _ensureSession(scope);
    await cache.commit(metadata.hash, partFile);
    cancellation.throwIfCancelled();
    _ensureSession(scope);
    final object = await cache.objectFile(metadata.hash);
    cancellation.throwIfCancelled();
    _ensureSession(scope);
    await _publishVerifiedOwnership(
      scope,
      remoteNode: remoteNode,
      metadata: metadata,
      existingBinding: existingBinding,
      targetMembership: targetMembership,
      openTargetMembership: openTargetMembership,
      repairOpenTargetMembership: repairOpenTargetMembership,
    );
    _ensureOperationSession(scope);
    _emit(
      DownloadProgress(
        phase: DownloadPhase.committed,
        bytes: metadata.size,
        total: metadata.size,
        resumed: result.resumed,
      ),
    );
    _ensureOperationSession(scope);
    return _MetadataSuccess(object);
  }

  Future<void> _publishVerifiedOwnership(
    _DownloadSessionScope scope, {
    required CloudNode remoteNode,
    required _DownloadMetadata metadata,
    OfflineFileRecord? existingBinding,
    OfflineTargetFileRecord? targetMembership,
    OfflineTargetFileRecord? openTargetMembership,
    required bool repairOpenTargetMembership,
  }) async {
    switch (mode) {
      case _DownloadMode.open:
        final membership = openTargetMembership;
        if (membership != null) {
          if (repairOpenTargetMembership) {
            await _indexTargetFile(
              scope,
              remoteNode,
              metadata,
              membership,
              ownershipTargetPath: membership.targetPath,
              ownershipTargetIncarnation: membership.targetIncarnation,
            );
          } else {
            await _ensureReadyTargetMembership(scope, membership, metadata);
          }
        }
        await onOpenVerified!(scope, metadata, cancellation);
      case _DownloadMode.direct:
        await _indexFile(
          scope,
          remoteNode,
          metadata,
          existingBinding: existingBinding,
        );
      case _DownloadMode.target:
        final membership = targetMembership;
        if (membership == null) {
          throw StateError('Target membership was not captured.');
        }
        await _indexTargetFile(
          scope,
          remoteNode,
          metadata,
          membership,
          ownershipTargetPath: targetPath!,
          ownershipTargetIncarnation: expectedTargetIncarnation!,
        );
    }
  }

  Future<void> _ensureReadyTargetMembership(
    _DownloadSessionScope scope,
    OfflineTargetFileRecord membership,
    _DownloadMetadata metadata,
  ) async {
    _ensureOperationSession(scope);
    final current = await targetIndex.getTargetFile(
      scope.session.email,
      membership.targetPath,
      membership.filePath,
      targetIncarnation: membership.targetIncarnation,
    );
    _ensureOperationSession(scope);
    if (current == null ||
        current.targetIncarnation != membership.targetIncarnation ||
        current.readiness != OfflineReadiness.ready ||
        !_hasCompleteTargetMetadata(current) ||
        current.hash != metadata.hash ||
        current.size != metadata.size) {
      throw const DownloadCancelled();
    }
  }

  Future<void> _indexTargetFile(
    _DownloadSessionScope scope,
    CloudNode freshNode,
    _DownloadMetadata metadata,
    OfflineTargetFileRecord membership, {
    required String ownershipTargetPath,
    required String ownershipTargetIncarnation,
  }) async {
    final index = targetIndex;
    final freshPath = _canonicalPathOrNull(freshNode.path);
    if (freshPath == null ||
        membership.targetPath != ownershipTargetPath ||
        membership.targetIncarnation != ownershipTargetIncarnation ||
        membership.filePath != freshPath) {
      throw const DownloadCancelled();
    }

    _ensureOperationSession(scope);
    final currentTarget = await index.getTarget(
      scope.session.email,
      membership.targetPath,
      targetIncarnation: membership.targetIncarnation,
    );
    _ensureOperationSession(scope);
    if (currentTarget == null ||
        currentTarget.state == OfflineTargetState.removing) {
      throw const DownloadCancelled();
    }
    var markedReady = false;
    try {
      markedReady = await index.markTargetFileReady(
        scope.session.email,
        targetPath: membership.targetPath,
        filePath: membership.filePath,
        targetIncarnation: membership.targetIncarnation,
        hash: metadata.hash,
        size: metadata.size,
        modifiedAt: freshNode.modifiedAt,
        revision: freshNode.revision,
        globalRevision: freshNode.globalRevision,
      );
      _ensureOperationSession(scope);
    } catch (_) {
      // The persistence call may complete after cancellation was requested.
      // Do not leave a newly-ready row behind in that case. A membership that
      // was already ready is valid ownership and must not be downgraded.
      if (markedReady &&
          membership.readiness != OfflineReadiness.ready &&
          (cancellation.isCancelled || !_isCurrentSession(scope))) {
        try {
          final restoredBytes = membership.bytesDone > metadata.size
              ? metadata.size
              : membership.bytesDone;
          await index.updateTargetFileReadiness(
            scope.session.email,
            targetPath: membership.targetPath,
            filePath: membership.filePath,
            targetIncarnation: membership.targetIncarnation,
            readiness: membership.readiness,
            bytesDone: restoredBytes,
            errorCode: membership.errorCode,
          );
        } catch (_) {
          // The target may have been removed concurrently. Preserve the
          // cancellation result rather than replacing it with cleanup noise.
        }
      }
      rethrow;
    }
    if (!markedReady) {
      // A target worker may have removed the membership while this operation
      // was queued or downloading. Never recreate ownership from a stale
      // operation.
      throw const DownloadCancelled();
    }

    // The target row is durable before this removal is attempted. Both calls
    // run under the account+hash coordinator, so a concurrent download or
    // removal cannot observe an ownership hand-off in the middle of the CAS
    // write sequence.
    final transientIndex = offlineFileIndex is TransientObjectIndex
        ? offlineFileIndex as TransientObjectIndex
        : null;
    if (transientIndex != null) {
      await transientIndex.removeTransient(scope.session.email, metadata.hash);
    }
    _ensureOperationSession(scope);
  }

  Future<_DownloadSessionScope> _requireSession() async {
    final epoch = authRepository.sessionEpoch;
    try {
      final session = await authRepository.requireFreshSession();
      final scope = _DownloadSessionScope(session: session, epoch: epoch);
      _ensureSession(scope);
      return scope;
    } on AuthFailure catch (failure) {
      throw DownloadFailure(switch (failure.type) {
        AuthFailureType.network => DownloadFailureType.network,
        AuthFailureType.timeout => DownloadFailureType.timeout,
        AuthFailureType.authRequired ||
        AuthFailureType.invalidCredentials => DownloadFailureType.authRequired,
        AuthFailureType.invalidResponse => DownloadFailureType.invalidResponse,
        AuthFailureType.service ||
        AuthFailureType.secureStorage => DownloadFailureType.service,
      }, failure.message);
    }
  }

  Future<_DownloadSessionScope> _requireTargetSession() async {
    final expectedEmail = expectedTargetEmail;
    final expectedEpoch = expectedTargetSessionEpoch;
    if (expectedEmail == null || expectedEpoch == null) {
      throw const DownloadFailure(
        DownloadFailureType.service,
        'Загрузка в офлайн-цель недоступна.',
      );
    }
    if (authRepository.sessionEpoch != expectedEpoch) {
      throw const DownloadCancelled();
    }
    final current = authRepository.currentSession;
    if (current == null ||
        current.email.trim().toLowerCase() != expectedEmail) {
      throw const DownloadCancelled();
    }
    try {
      final session = await authRepository.requireFreshSession();
      final scope = _DownloadSessionScope(
        session: session,
        epoch: expectedEpoch,
      );
      if (session.email.trim().toLowerCase() != expectedEmail) {
        throw const DownloadCancelled();
      }
      _ensureSession(scope);
      return scope;
    } on AuthFailure catch (failure) {
      throw DownloadFailure(switch (failure.type) {
        AuthFailureType.network => DownloadFailureType.network,
        AuthFailureType.timeout => DownloadFailureType.timeout,
        AuthFailureType.authRequired ||
        AuthFailureType.invalidCredentials => DownloadFailureType.authRequired,
        AuthFailureType.invalidResponse => DownloadFailureType.invalidResponse,
        AuthFailureType.service ||
        AuthFailureType.secureStorage => DownloadFailureType.service,
      }, failure.message);
    }
  }

  void _ensureOperationSession(_DownloadSessionScope scope) {
    cancellation.throwIfCancelled();
    _ensureSession(scope);
  }

  void _ensureSession(_DownloadSessionScope scope) {
    if (!_isCurrentSession(scope)) throw const DownloadCancelled();
  }

  bool _isCurrentSession(_DownloadSessionScope scope) {
    final current = authRepository.currentSession;
    return authRepository.sessionEpoch == scope.epoch &&
        current != null &&
        current.email.trim().toLowerCase() ==
            scope.session.email.trim().toLowerCase();
  }

  Future<void> _indexFile(
    _DownloadSessionScope scope,
    CloudNode freshNode,
    _DownloadMetadata metadata, {
    OfflineFileRecord? existingBinding,
  }) async {
    cancellation.throwIfCancelled();
    _ensureSession(scope);
    final name = freshNode.name.trim().isEmpty
        ? existingBinding?.name ?? freshNode.name
        : freshNode.name;
    await offlineFileIndex.upsert(
      scope.session.email,
      OfflineFileRecord(
        path: freshNode.path,
        name: name,
        hash: metadata.hash,
        size: metadata.size,
        modifiedAt: freshNode.modifiedAt ?? existingBinding?.modifiedAt,
        revision: freshNode.revision ?? existingBinding?.revision,
        globalRevision:
            freshNode.globalRevision ?? existingBinding?.globalRevision,
        cachedAt: DateTime.now().toUtc(),
      ),
    );
    final transientIndex = offlineFileIndex is TransientObjectIndex
        ? offlineFileIndex as TransientObjectIndex
        : null;
    if (transientIndex != null) {
      await transientIndex.removeTransient(scope.session.email, metadata.hash);
    }
    cancellation.throwIfCancelled();
    _ensureSession(scope);
  }

  Future<CloudNode> _stat(String path) async {
    return api.stat(path);
  }

  String? _canonicalPathOrNull(String path) {
    try {
      return normalizeOfflineRemotePath(path);
    } on ArgumentError {
      return null;
    }
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
    if (handle case final VerifiedDownloadHandle verified) {
      verified.verifiedNode = _verifiedNode;
    }
    if (!_result.isCompleted) _result.complete(file);
    return file;
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (!_result.isCompleted) _result.completeError(error, stackTrace);
  }
}

/// Internal lifecycle record for a repository operation that has no public
/// handle. Shutdown cancels its token and awaits this completion future before
/// closing the transport.
final class _TrackedRepositoryOperation {
  final cancellation = DownloadCancellationToken();
  final _completion = Completer<void>();

  Future<void> get completion => _completion.future;

  void cancel() => cancellation.cancel();

  void complete() {
    if (!_completion.isCompleted) _completion.complete();
  }
}

final class _ReconciliationReferenceFailure implements Exception {
  const _ReconciliationReferenceFailure(this.errors);

  final List<Object> errors;
}

final class _DownloadHandle implements VerifiedDownloadHandle {
  _DownloadHandle({
    required this.progress,
    required this.result,
    required void Function() onCancel,
  }) : _onCancel = onCancel;

  @override
  final Stream<DownloadProgress> progress;

  @override
  final Future<File> result;

  @override
  CloudNode? verifiedNode;

  final void Function() _onCancel;

  @override
  void cancel() => _onCancel();
}

enum _DownloadMode { direct, open, target }

final class _DownloadMetadata {
  const _DownloadMetadata({required this.size, required this.hash});

  final int size;
  final String hash;
}

final class _MetadataRunResult {
  const _MetadataRunResult({required this.file, required this.metadata});

  final File file;
  final _DownloadMetadata metadata;
}

final class _DownloadMetadataResolution {
  const _DownloadMetadataResolution({
    required this.remoteNode,
    required this.metadata,
  });

  final CloudNode remoteNode;
  final _DownloadMetadata metadata;
}

sealed class _MetadataAttempt {}

final class _MetadataSuccess extends _MetadataAttempt {
  _MetadataSuccess(this.file);

  final File file;
}

final class _MetadataRetry extends _MetadataAttempt {
  _MetadataRetry(this.resolution);

  final _DownloadMetadataResolution resolution;
}

final class _DownloadSessionScope {
  const _DownloadSessionScope({required this.session, required this.epoch});

  final CloudSession session;
  final int epoch;
}

final class _TransientAccount {
  const _TransientAccount({required this.email, required this.accountKey});

  final String email;
  final String accountKey;
}

final class _ProtectedOpen {
  _ProtectedOpen({
    required this.account,
    required this.generation,
    required String hash,
  }) : hash = normalizeCloudHash(hash);

  final _TransientAccount account;
  final int generation;
  final String hash;

  String get accountKey => account.accountKey;
}

enum _TransientObjectState { missing, file, other }

bool _isFileUnderTarget(String targetPath, String filePath) {
  if (filePath == '/' || filePath == targetPath) return false;
  return targetPath == '/'
      ? filePath.startsWith('/')
      : filePath.startsWith('$targetPath/');
}
