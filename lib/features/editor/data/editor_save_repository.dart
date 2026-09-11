import 'dart:async';
import 'dart:io';

import '../../../cloud_mail/api/cloud_mail_api.dart';
import '../../../cloud_mail/probe/cloud_hash.dart';
import '../../../cloud_mail/transport/cloud_write_transport.dart';
import '../../../core/errors/cloud_failure.dart';
import '../../../features/auth/application/auth_repository.dart';
import '../../../features/auth/domain/auth_failure.dart';
import '../../../features/auth/domain/cloud_session.dart';
import '../../../features/browser/domain/cloud_node.dart';
import '../../../local/cache/application_cache_root.dart';
import '../../../local/cache/cloud_cache_coordinator.dart';
import '../../../local/cache/content_addressed_file_cache.dart';
import '../../download/domain/download_cancellation.dart';
import '../../download/domain/download_failure.dart';
import '../../offline/application/offline_file_index.dart';
import '../application/editor_save_repository.dart';

typedef EditorCacheFactory = ContentAddressedFileCache Function(String email);

/// Production conflict-safe save service for the future text editor.
///
/// The service owns no editor/widget state.  It verifies the remote baseline,
/// prepares a content-addressed object under the shared account/hash lock,
/// performs upload/register, verifies the returned node with a fresh stat, and
/// only then conditionally hands the new object to local ownership.
final class EditorSaveRepository implements EditorSaveService {
  EditorSaveRepository({
    required CloudMailApi api,
    required AuthRepository authRepository,
    required EditorWriteTransport writeTransport,
    required OfflineFileIndex offlineFileIndex,
    OfflineTargetIndex? offlineTargetIndex,
    TransientObjectIndex? transientObjectIndex,
    EditorCacheFactory? cacheFactory,
    Directory? cacheRoot,
    CacheRootProvider? rootProvider,
    required CloudCacheCoordinator coordinator,
    DateTime Function()? clock,
  }) : _api = api,
       _authRepository = authRepository,
       _writeTransport = writeTransport,
       _offlineFileIndex = offlineFileIndex,
       _targetIndex =
           offlineTargetIndex ??
           (offlineFileIndex is OfflineTargetIndex
               ? offlineFileIndex as OfflineTargetIndex
               : null),
       _transientObjectIndex =
           transientObjectIndex ??
           (offlineFileIndex is TransientObjectIndex
               ? offlineFileIndex as TransientObjectIndex
               : null),
       _cacheFactory =
           cacheFactory ??
           ((email) => ContentAddressedFileCache(
             email: email,
             root: cacheRoot,
             rootProvider: rootProvider,
           )),
       _coordinator = coordinator,
       _clock = clock ?? DateTime.now {
    if (cacheFactory != null && (cacheRoot != null || rootProvider != null)) {
      throw ArgumentError(
        'cacheFactory cannot be combined with cacheRoot or rootProvider.',
      );
    }
  }

  final CloudMailApi _api;
  final AuthRepository _authRepository;
  final EditorWriteTransport _writeTransport;
  final OfflineFileIndex _offlineFileIndex;
  final OfflineTargetIndex? _targetIndex;
  final TransientObjectIndex? _transientObjectIndex;
  final EditorCacheFactory _cacheFactory;
  final CloudCacheCoordinator _coordinator;
  final DateTime Function() _clock;

  final _active = <_EditorOperation>{};
  bool _closed = false;
  Future<void>? _closeFuture;

  @override
  Future<EditorConflictCheckResult> checkConflict(
    EditorSaveBaseline baseline, {
    EditorSaveCancellation? cancellation,
  }) => _runOperation(
    cancellation,
    (scope, token) => _withPathLock(
      scope,
      token,
      baseline.path,
      () => _checkConflict(scope, token, baseline),
    ),
  );

  @override
  Future<EditorSaveResult> save(
    EditorSaveBaseline baseline,
    List<int> bytes, {
    EditorSaveChoice choice = EditorSaveChoice.unchanged,
    EditorSaveCancellation? cancellation,
    void Function(EditorSaveProgress progress)? onProgress,
  }) {
    return _runOperation(cancellation, (scope, token) async {
      return _saveInScope(scope, token, baseline, bytes, choice, onProgress);
    });
  }

  @override
  Future<EditorSaveResult> saveRequest(
    EditorSaveRequest request, {
    EditorSaveCancellation? cancellation,
    void Function(EditorSaveProgress progress)? onProgress,
  }) => save(
    request.baseline,
    request.bytes,
    choice: request.choice,
    cancellation: cancellation,
    onProgress: onProgress,
  );

  /// Named convenience spelling for callers that do not use [save].
  Future<EditorSaveResult> saveBytes({
    required EditorSaveBaseline baseline,
    required List<int> bytes,
    EditorSaveChoice choice = EditorSaveChoice.unchanged,
    EditorSaveCancellation? cancellation,
    void Function(EditorSaveProgress progress)? onProgress,
  }) => save(
    baseline,
    bytes,
    choice: choice,
    cancellation: cancellation,
    onProgress: onProgress,
  );

  Future<T> _runOperation<T>(
    EditorSaveCancellation? externalCancellation,
    Future<T> Function(
      _EditorSessionScope scope,
      DownloadCancellationToken token,
    )
    body,
  ) async {
    _ensureOpen();
    final token = DownloadCancellationToken();
    final operation = _EditorOperation(token);
    _active.add(operation);
    StreamSubscription<void>? externalSubscription;
    StreamSubscription<CloudSession?>? sessionSubscription;
    _EditorSessionScope? scope;
    try {
      if (externalCancellation != null) {
        if (externalCancellation.isCancelled) token.cancel();
        externalSubscription = externalCancellation.cancellations.listen((_) {
          token.cancel();
        });
      }
      final startingEpoch = _authRepository.sessionEpoch;
      final session = await _freshSession();
      scope = _EditorSessionScope(
        session: session,
        email: _normalizeEmail(session.email),
        epoch: startingEpoch,
      );
      _ensureScope(scope, token);
      sessionSubscription = _authRepository.sessionChanges.listen((_) {
        if (!_isCurrentScope(scope!)) token.cancel();
      });
      _ensureScope(scope, token);
      return await body(scope, token);
    } catch (error) {
      if (error is EditorSaveFailure) rethrow;
      if (error is CloudWriteFailure) {
        throw _fromWriteFailure(error);
      }
      if (error is DownloadCancelled || token.isCancelled) {
        throw _cancelledFailure();
      }
      if (error is ArgumentError) {
        throw EditorSaveFailure(
          EditorSaveFailureType.invalidRequest,
          'Параметры сохранения недействительны.',
        );
      }
      throw EditorSaveFailure(
        EditorSaveFailureType.service,
        'Не удалось выполнить сохранение.',
      );
    } finally {
      await sessionSubscription?.cancel();
      await externalSubscription?.cancel();
      await token.close();
      operation.complete();
      _active.remove(operation);
    }
  }

  Future<T> _withPathLock<T>(
    _EditorSessionScope scope,
    DownloadCancellationToken token,
    String path,
    Future<T> Function() body,
  ) async {
    _ensureScope(scope, token);
    final cache = _cacheFactory(scope.email);
    final release = await _coordinator.acquire(
      cloudCachePathKey(cache.accountDirectoryName, path),
      token,
      kind: CloudCacheLockKind.path,
    );
    try {
      _ensureScope(scope, token);
      return await body();
    } finally {
      release();
    }
  }

  Future<EditorConflictCheckResult> _checkConflict(
    _EditorSessionScope scope,
    DownloadCancellationToken token,
    EditorSaveBaseline baseline, {
    void Function(EditorSaveProgress progress)? onProgress,
  }) async {
    _emit(onProgress, EditorSavePhase.checkingConflict, 0, null);
    _ensureScope(scope, token);
    final currentNode = await _freshStat(scope, token, baseline.path);
    if (currentNode == null) {
      final failure = const EditorSaveFailure(
        EditorSaveFailureType.notFound,
        'Удалённый файл недоступен.',
      );
      return EditorConflictCheckResult.conflict(null, failure: failure);
    }
    final current = _metadata(currentNode);
    if (current == null) {
      return EditorConflictCheckResult.conflict(
        null,
        failure: const EditorSaveFailure(
          EditorSaveFailureType.invalidResponse,
          'Mail.ru вернул неполные метаданные файла.',
        ),
      );
    }
    final matches = _matchesBaseline(baseline, current);
    return matches
        ? EditorConflictCheckResult.unchanged(current)
        : EditorConflictCheckResult.conflict(current);
  }

  Future<EditorSaveResult> _saveInScope(
    _EditorSessionScope scope,
    DownloadCancellationToken token,
    EditorSaveBaseline baseline,
    List<int> originalBytes,
    EditorSaveChoice choice,
    void Function(EditorSaveProgress progress)? onProgress,
  ) async {
    _validateChoice(choice);
    final bytes = _copyAndValidateBytes(originalBytes);
    final ownership = await _captureOwnership(scope, token, baseline.path);
    final cache = _cacheFactory(scope.email);
    void Function()? releaseTarget;
    if (ownership.kind == _EditorOwnershipKind.inherited) {
      releaseTarget = await _coordinator.acquire(
        cloudCacheTargetKey(cache.accountDirectoryName, ownership.targetPath!),
        token,
        kind: CloudCacheLockKind.target,
      );
    }
    try {
      final releasePath = await _coordinator.acquire(
        cloudCachePathKey(cache.accountDirectoryName, baseline.path),
        token,
        kind: CloudCacheLockKind.path,
      );
      try {
        final check = await _checkConflict(
          scope,
          token,
          baseline,
          onProgress: onProgress,
        );
        final current = check.current;
        if (current == null) throw _conflictFailure(check.failure);
        if (!current.isFile) {
          throw const EditorSaveFailure(
            EditorSaveFailureType.conflict,
            'Удалённый объект больше не является файлом.',
          );
        }
        if (choice == EditorSaveChoice.unchanged && check.isConflict) {
          // Never upload an unchanged save after the fresh-stat conflict check.
          throw const EditorSaveFailure(
            EditorSaveFailureType.conflict,
            'Удалённый файл изменился. Сначала проверьте конфликт.',
          );
        }

        _emit(onProgress, EditorSavePhase.hashing, 0, bytes.length);
        final hash = calculateCloudHash(bytes);
        _ensureScope(scope, token);
        final releaseHash = await _coordinator.acquire(
          cloudCacheHashKey(cache.accountDirectoryName, hash),
          token,
          kind: CloudCacheLockKind.hash,
        );
        try {
          _ensureScope(scope, token);
          final object = await _prepareObject(
            cache,
            hash: hash,
            bytes: bytes,
            scope: scope,
            token: token,
            onProgress: onProgress,
          );

          // Protect the prepared object before the first network registration.
          final preparedFailure = await _touchTransient(
            scope,
            token,
            hash: hash,
            size: bytes.length,
          );
          if (preparedFailure != null) throw preparedFailure;
          _ensureScope(scope, token);

          _emit(
            onProgress,
            EditorSavePhase.uploading,
            bytes.length,
            bytes.length,
          );
          late final CloudWriteResult writeResult;
          var registered = false;
          try {
            writeResult = await _writeTransport.uploadAndRegister(
              object,
              remotePath: baseline.path,
              conflict: _wireConflict(choice),
              expectedHash: hash,
              expectedSize: bytes.length,
              expectedEmail: scope.email,
              expectedSessionEpoch: scope.epoch,
              cancellation: token,
            );
            // Any failure after this point may mean the server already saved.
            registered = true;
            _ensureScope(scope, token);
            _validateWriteResult(
              writeResult,
              requestedPath: baseline.path,
              expectedHash: hash,
              expectedSize: bytes.length,
              choice: choice,
            );

            _emit(
              onProgress,
              EditorSavePhase.verifyingRemote,
              bytes.length,
              bytes.length,
            );
            final remoteNode = await _postStat(
              scope,
              token,
              writeResult.returnedPath,
              expectedHash: hash,
              expectedSize: bytes.length,
            );
            _ensureScope(scope, token);
            final remoteMetadata = _metadata(remoteNode);
            if (remoteMetadata == null) {
              throw const EditorSaveFailure(
                EditorSaveFailureType.invalidResponse,
                'Проверка сохранённого файла не пройдена.',
              );
            }

            _emit(
              onProgress,
              EditorSavePhase.committingOwnership,
              bytes.length,
              bytes.length,
            );
            final ownershipResult = await _commitOwnership(
              scope,
              token,
              ownership,
              remoteNode,
              hash: hash,
              size: bytes.length,
              choice: choice,
              transientPrepared: true,
            );
            _ensureScope(scope, token);
            final result = EditorSaveResult(
              remoteNode: remoteMetadata,
              choice: choice,
              ownershipPolicy: ownershipResult.policy,
              partialSuccess: ownershipResult.failure == null
                  ? null
                  : EditorPartialSuccess(
                      verifiedRemoteNode: remoteMetadata,
                      localFailure: ownershipResult.failure!,
                    ),
            );
            _emit(
              onProgress,
              EditorSavePhase.completed,
              bytes.length,
              bytes.length,
            );
            return result;
          } catch (error) {
            if (error is CloudWriteFailure && error.mayHaveSaved) {
              registered = true;
            }
            if (registered) {
              final statusCode = error is EditorSaveFailure
                  ? error.statusCode
                  : null;
              throw _remoteOutcomeUnknown(statusCode: statusCode);
            }
            rethrow;
          }
        } finally {
          releaseHash();
        }
      } finally {
        releasePath();
      }
    } finally {
      releaseTarget?.call();
    }
  }

  Future<File> _prepareObject(
    ContentAddressedFileCache cache, {
    required String hash,
    required List<int> bytes,
    required _EditorSessionScope scope,
    required DownloadCancellationToken token,
    required void Function(EditorSaveProgress progress)? onProgress,
  }) async {
    File? part;
    IOSink? sink;
    try {
      part = await cache.partFile(hash);
      _ensureScope(scope, token);
      if (await part.exists()) await part.delete();
      sink = part.openWrite(mode: FileMode.write);
      const chunkSize = 64 * 1024;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        _ensureScope(scope, token);
        final end = (offset + chunkSize).clamp(0, bytes.length).toInt();
        sink.add(bytes.sublist(offset, end));
        _emit(onProgress, EditorSavePhase.preparingCache, end, bytes.length);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      _ensureScope(scope, token);
      final actualSize = await part.length();
      if (actualSize != bytes.length) {
        throw const EditorSaveFailure(
          EditorSaveFailureType.integrity,
          'Размер локального содержимого не совпадает.',
        );
      }
      final actualHash = await calculateCloudFileHash(part);
      _ensureScope(scope, token);
      if (actualHash != hash) {
        throw const EditorSaveFailure(
          EditorSaveFailureType.integrity,
          'Хеш локального содержимого не совпадает.',
        );
      }

      final existing = await cache.lookup(hash, expectedSize: bytes.length);
      _ensureScope(scope, token);
      if (existing != null) {
        final existingHash = await calculateCloudFileHash(existing);
        _ensureScope(scope, token);
        if (existingHash == hash) {
          await _deletePartQuietly(part);
          return existing;
        }
        await cache.discardObject(hash);
      }
      await cache.commit(hash, part);
      _ensureScope(scope, token);
      final object = await cache.objectFile(hash);
      final committedSize = await object.length();
      final committedHash = await calculateCloudFileHash(object);
      _ensureScope(scope, token);
      if (committedSize != bytes.length || committedHash != hash) {
        await _deleteQuietly(object);
        throw const EditorSaveFailure(
          EditorSaveFailureType.integrity,
          'Локальный объект не прошёл проверку.',
        );
      }
      return object;
    } on EditorSaveFailure {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (part != null) await _deletePartQuietly(part);
      rethrow;
    } on DownloadCancelled {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (part != null) await _deletePartQuietly(part);
      rethrow;
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (part != null) await _deletePartQuietly(part);
      throw EditorSaveFailure(
        EditorSaveFailureType.disk,
        'Не удалось подготовить локальный объект.',
      );
    }
  }

  Future<CloudNode> _postStat(
    _EditorSessionScope scope,
    DownloadCancellationToken token,
    String returnedPath, {
    required String expectedHash,
    required int expectedSize,
  }) async {
    final path = _validateReturnedPath(returnedPath);
    _ensureScope(scope, token);
    late final CloudNode node;
    try {
      node = await _api.stat(path);
    } on CloudFailure catch (failure) {
      throw _fromCloudFailure(failure);
    }
    _ensureScope(scope, token);
    final metadata = _metadata(node);
    if (metadata == null ||
        metadata.path != path ||
        metadata.type != EditorRemoteNodeType.file ||
        metadata.hash != expectedHash ||
        metadata.size != expectedSize) {
      throw const EditorSaveFailure(
        EditorSaveFailureType.invalidResponse,
        'Проверка сохранённого файла не пройдена.',
      );
    }
    return node;
  }

  Future<_EditorOwnershipSnapshot> _captureOwnership(
    _EditorSessionScope scope,
    DownloadCancellationToken token,
    String path,
  ) async {
    final targetIndex = _targetIndex;
    if (targetIndex == null) {
      return const _EditorOwnershipSnapshot.onlineOnly();
    }
    try {
      final states = await targetIndex.lookupEffectiveAvailability(
        scope.email,
        [path],
      );
      _ensureScope(scope, token);
      final state = states[path];
      final direct = state?.directRecord;
      if (state?.source == OfflineAvailabilitySource.direct && direct != null) {
        return _EditorOwnershipSnapshot.direct(
          path: path,
          expectedHash: direct.hash,
        );
      }
      final membership = state?.targetFile;
      if (state?.source == OfflineAvailabilitySource.inherited &&
          membership != null &&
          membership.readiness == OfflineReadiness.ready &&
          membership.hash != null &&
          membership.size != null) {
        return _EditorOwnershipSnapshot.inherited(
          targetPath: membership.targetPath,
          targetIncarnation: membership.targetIncarnation,
          filePath: membership.filePath,
          expectedHash: membership.hash!,
        );
      }
    } on EditorSaveFailure {
      rethrow;
    } on DownloadCancelled {
      rethrow;
    } catch (_) {
      // A local policy read is advisory.  The safe fallback is a transient
      // reference after remote verification, never an unconditional upsert.
    }
    return const _EditorOwnershipSnapshot.onlineOnly();
  }

  Future<_EditorOwnershipResult> _commitOwnership(
    _EditorSessionScope scope,
    DownloadCancellationToken token,
    _EditorOwnershipSnapshot snapshot,
    CloudNode remoteNode, {
    required String hash,
    required int size,
    required EditorSaveChoice choice,
    required bool transientPrepared,
  }) async {
    _ensureScope(scope, token);
    if (choice == EditorSaveChoice.copy) {
      return _touchAsPolicy(
        scope,
        token,
        hash: hash,
        size: size,
        policy: EditorOwnershipPolicy.copy,
      );
    }
    if (snapshot.kind == _EditorOwnershipKind.onlineOnly) {
      return _touchAsPolicy(
        scope,
        token,
        hash: hash,
        size: size,
        policy: EditorOwnershipPolicy.onlineOnly,
      );
    }

    var touched = transientPrepared;
    EditorSaveFailure? touchFailure;
    if (!touched) {
      final touchResult = await _touchTransient(
        scope,
        token,
        hash: hash,
        size: size,
      );
      touched = touchResult == null;
      touchFailure = touchResult;
    }

    try {
      if (snapshot.kind == _EditorOwnershipKind.direct) {
        final capability = _offlineFileIndex;
        if (capability is! ConditionalOfflineFileOwnership) {
          return _fallbackOwnership(
            touched: touched,
            touchFailure: touchFailure,
          );
        }
        final conditionalCapability =
            capability as ConditionalOfflineFileOwnership;
        final applied = await conditionalCapability.updateDirectIfMatches(
          scope.email,
          path: snapshot.path,
          expectedHash: snapshot.expectedHash,
          replacement: _directReplacement(remoteNode, hash: hash, size: size),
        );
        _ensureScope(scope, token);
        if (applied) {
          final removalFailure = touched
              ? await _removeTransient(scope, token, hash)
              : null;
          return _EditorOwnershipResult(
            policy: EditorOwnershipPolicy.direct,
            failure: removalFailure,
          );
        }
        if (!touched) {
          final retry = await _touchTransient(
            scope,
            token,
            hash: hash,
            size: size,
          );
          touchFailure ??= retry;
          touched = retry == null;
        }
        return _EditorOwnershipResult(
          policy: EditorOwnershipPolicy.fallbackTransient,
          failure: touched ? null : touchFailure ?? _localOwnershipFailure(),
        );
      }

      final targetCapability = _targetIndex;
      if (targetCapability is! ConditionalOfflineTargetOwnership) {
        return _fallbackOwnership(touched: touched, touchFailure: touchFailure);
      }
      final conditionalTargetCapability =
          targetCapability as ConditionalOfflineTargetOwnership;
      final applied = await conditionalTargetCapability
          .updateTargetFileIfMatches(
            scope.email,
            targetPath: snapshot.targetPath!,
            targetIncarnation: snapshot.targetIncarnation!,
            filePath: snapshot.path,
            expectedHash: snapshot.expectedHash,
            hash: hash,
            size: size,
            modifiedAt: remoteNode.modifiedAt,
            revision: remoteNode.revision,
            globalRevision: remoteNode.globalRevision,
          );
      _ensureScope(scope, token);
      if (applied) {
        final removalFailure = touched
            ? await _removeTransient(scope, token, hash)
            : null;
        return _EditorOwnershipResult(
          policy: EditorOwnershipPolicy.inherited,
          failure: removalFailure,
        );
      }
      if (!touched) {
        final retry = await _touchTransient(
          scope,
          token,
          hash: hash,
          size: size,
        );
        touchFailure ??= retry;
        touched = retry == null;
      }
      return _EditorOwnershipResult(
        policy: EditorOwnershipPolicy.fallbackTransient,
        failure: touched ? null : touchFailure ?? _localOwnershipFailure(),
      );
    } catch (_) {
      _ensureScope(scope, token);
      if (!touched) {
        final retry = await _touchTransient(
          scope,
          token,
          hash: hash,
          size: size,
        );
        touchFailure ??= retry;
        touched = retry == null;
      }
      return _EditorOwnershipResult(
        policy: EditorOwnershipPolicy.fallbackTransient,
        failure: touched ? null : touchFailure ?? _localOwnershipFailure(),
      );
    }
  }

  Future<_EditorOwnershipResult> _touchAsPolicy(
    _EditorSessionScope scope,
    DownloadCancellationToken token, {
    required String hash,
    required int size,
    required EditorOwnershipPolicy policy,
  }) async {
    final failure = await _touchTransient(scope, token, hash: hash, size: size);
    return _EditorOwnershipResult(policy: policy, failure: failure);
  }

  _EditorOwnershipResult _fallbackOwnership({
    required bool touched,
    required EditorSaveFailure? touchFailure,
  }) {
    return _EditorOwnershipResult(
      policy: EditorOwnershipPolicy.fallbackTransient,
      failure: touched ? null : touchFailure ?? _localOwnershipFailure(),
    );
  }

  Future<EditorSaveFailure?> _touchTransient(
    _EditorSessionScope scope,
    DownloadCancellationToken token, {
    required String hash,
    required int size,
  }) async {
    final index = _transientObjectIndex;
    if (index == null) return _localOwnershipFailure();
    try {
      _ensureScope(scope, token);
      await index.touchTransient(
        scope.email,
        TransientObjectRecord(
          hash: hash,
          size: size,
          lastAccessedAt: _clock().toUtc(),
        ),
      );
      _ensureScope(scope, token);
      return null;
    } catch (_) {
      _ensureScope(scope, token);
      return _localOwnershipFailure();
    }
  }

  Future<EditorSaveFailure?> _removeTransient(
    _EditorSessionScope scope,
    DownloadCancellationToken token,
    String hash,
  ) async {
    final index = _transientObjectIndex;
    if (index == null) return null;
    try {
      _ensureScope(scope, token);
      await index.removeTransient(scope.email, hash);
      _ensureScope(scope, token);
      return null;
    } catch (_) {
      _ensureScope(scope, token);
      return _localOwnershipFailure();
    }
  }

  OfflineFileRecord _directReplacement(
    CloudNode remoteNode, {
    required String hash,
    required int size,
  }) => OfflineFileRecord(
    path: remoteNode.path,
    name: remoteNode.name.trim().isEmpty
        ? _basename(remoteNode.path)
        : remoteNode.name,
    hash: hash,
    size: size,
    modifiedAt: remoteNode.modifiedAt,
    revision: remoteNode.revision,
    globalRevision: remoteNode.globalRevision,
    cachedAt: _clock().toUtc(),
  );

  EditorSaveFailure _conflictFailure(EditorSaveFailure? detail) =>
      EditorSaveFailure(
        EditorSaveFailureType.conflict,
        'Удалённый файл недоступен или изменился.',
        statusCode: detail?.statusCode,
      );

  EditorSaveFailure _remoteOutcomeUnknown({
    int? statusCode,
  }) => EditorSaveFailure(
    EditorSaveFailureType.remoteOutcomeUnknown,
    'Удалённый результат сохранения не удалось подтвердить. Проверьте файл вручную.',
    statusCode: statusCode,
    mayHaveSaved: true,
  );

  List<int> _copyAndValidateBytes(List<int> bytes) {
    if (bytes.length > editorMaxBytes) {
      throw const EditorSaveFailure(
        EditorSaveFailureType.invalidRequest,
        'Размер редактора превышает 10 MiB.',
      );
    }
    for (final byte in bytes) {
      if (byte < 0 || byte > 255) {
        throw const EditorSaveFailure(
          EditorSaveFailureType.invalidRequest,
          'Содержимое редактора недействительно.',
        );
      }
    }
    return List<int>.from(bytes, growable: false);
  }

  void _validateChoice(EditorSaveChoice choice) {
    // Exhaustiveness protects this service if a new choice is added without
    // defining its wire and ownership semantics.
    switch (choice) {
      case EditorSaveChoice.unchanged:
      case EditorSaveChoice.overwrite:
      case EditorSaveChoice.copy:
        return;
    }
  }

  CloudWriteConflictMode _wireConflict(EditorSaveChoice choice) =>
      switch (choice) {
        // A fresh stat has already proved that the captured baseline is still
        // current. The existing remote object must therefore be rewritten;
        // strict would incorrectly reject the normal unchanged save.
        EditorSaveChoice.unchanged => CloudWriteConflictMode.rewrite,
        EditorSaveChoice.overwrite => CloudWriteConflictMode.rewrite,
        EditorSaveChoice.copy => CloudWriteConflictMode.rename,
      };

  void _validateWriteResult(
    CloudWriteResult result, {
    required String requestedPath,
    required String expectedHash,
    required int expectedSize,
    required EditorSaveChoice choice,
  }) {
    if (result.conflict != _wireConflict(choice) ||
        result.identity.hash.trim().toUpperCase() != expectedHash ||
        result.identity.size != expectedSize ||
        result.requestedPath != requestedPath) {
      throw const EditorSaveFailure(
        EditorSaveFailureType.integrity,
        'Сервер вернул другую идентичность содержимого.',
      );
    }
    final returned = _validateReturnedPath(result.returnedPath);
    if (choice != EditorSaveChoice.copy && returned != requestedPath) {
      throw const EditorSaveFailure(
        EditorSaveFailureType.invalidResponse,
        'Сервер вернул другой путь файла.',
      );
    }
    if (choice == EditorSaveChoice.copy &&
        (returned == requestedPath ||
            editorParentPath(returned) != editorParentPath(requestedPath))) {
      throw const EditorSaveFailure(
        EditorSaveFailureType.invalidResponse,
        'Сервер вернул недопустимый путь копии.',
      );
    }
  }

  String _validateReturnedPath(String value) {
    final trimmed = value.trim();
    if (trimmed != value || value.endsWith('/')) {
      throw const EditorSaveFailure(
        EditorSaveFailureType.invalidResponse,
        'Сервер вернул недопустимый путь файла.',
      );
    }
    try {
      final normalized = normalizeEditorPath(value);
      if (normalized != value) {
        throw const EditorSaveFailure(
          EditorSaveFailureType.invalidResponse,
          'Сервер вернул недопустимый путь файла.',
        );
      }
      return normalized;
    } on EditorSaveFailure {
      rethrow;
    } on ArgumentError {
      throw const EditorSaveFailure(
        EditorSaveFailureType.invalidResponse,
        'Сервер вернул недопустимый путь файла.',
      );
    }
  }

  Future<CloudNode?> _freshStat(
    _EditorSessionScope scope,
    DownloadCancellationToken token,
    String path,
  ) async {
    _ensureScope(scope, token);
    try {
      final node = await _api.stat(path);
      _ensureScope(scope, token);
      return node;
    } on CloudFailure catch (failure) {
      _ensureScope(scope, token);
      if (failure.type == CloudFailureType.notFound) return null;
      throw _fromCloudFailure(failure);
    }
  }

  EditorRemoteMetadata? _metadata(CloudNode node) {
    try {
      return EditorRemoteMetadata(
        path: node.path,
        type: switch (node.type) {
          CloudNodeType.file => EditorRemoteNodeType.file,
          CloudNodeType.folder => EditorRemoteNodeType.folder,
          CloudNodeType.unknown => EditorRemoteNodeType.unknown,
        },
        name: node.name,
        hash: node.hash,
        size: node.size,
        modifiedAt: node.modifiedAt,
        revision: node.revision,
        globalRevision: node.globalRevision,
      );
    } on ArgumentError {
      return null;
    }
  }

  bool _matchesBaseline(
    EditorSaveBaseline baseline,
    EditorRemoteMetadata current,
  ) {
    if (current.path != baseline.path ||
        current.type != EditorRemoteNodeType.file ||
        current.hash != baseline.hash ||
        current.size != baseline.size) {
      return false;
    }
    if (!_sameConservatively(baseline.modifiedAt, current.modifiedAt)) {
      return false;
    }
    if (!_sameConservatively(baseline.revision, current.revision)) {
      return false;
    }
    if (!_sameConservatively(baseline.globalRevision, current.globalRevision)) {
      return false;
    }
    return true;
  }

  bool _sameConservatively(Object? expected, Object? actual) {
    if (expected == null && actual == null) return true;
    if (expected == null || actual == null) return false;
    if (expected is DateTime && actual is DateTime) {
      return expected.toUtc().microsecondsSinceEpoch ==
          actual.toUtc().microsecondsSinceEpoch;
    }
    return expected == actual;
  }

  Future<CloudSession> _freshSession() async {
    try {
      return await _authRepository.requireFreshSession();
    } on AuthFailure catch (failure) {
      throw _fromAuthFailure(failure);
    }
  }

  String _normalizeEmail(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) {
      throw const EditorSaveFailure(
        EditorSaveFailureType.authRequired,
        'Требуется вход в Mail.ru.',
      );
    }
    return normalized;
  }

  bool _isCurrentScope(_EditorSessionScope scope) {
    final current = _authRepository.currentSession;
    return _authRepository.sessionEpoch == scope.epoch &&
        current != null &&
        current.email.trim().toLowerCase() == scope.email;
  }

  void _ensureScope(
    _EditorSessionScope scope,
    DownloadCancellationToken token,
  ) {
    if (token.isCancelled || !_isCurrentScope(scope)) {
      throw _cancelledFailure();
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Editor save repository is closed.');
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    final active = _active.toList(growable: false);
    for (final operation in active) {
      operation.cancel();
    }
    final closing = _finishClose(active);
    _closeFuture = closing;
    return closing;
  }

  Future<void> _finishClose(List<_EditorOperation> active) async {
    await Future.wait(
      active.map((operation) => operation.completion),
      eagerError: false,
    );
    _writeTransport.close();
  }

  void _emit(
    void Function(EditorSaveProgress progress)? onProgress,
    EditorSavePhase phase,
    int bytes,
    int? total,
  ) {
    if (onProgress == null) return;
    try {
      onProgress(EditorSaveProgress(phase: phase, bytes: bytes, total: total));
    } catch (_) {
      // A diagnostic callback must not change the save result.
    }
  }

  EditorSaveFailure _localOwnershipFailure() => const EditorSaveFailure(
    EditorSaveFailureType.disk,
    'Удалённый файл сохранён, но локальная офлайн-связь не обновлена.',
  );

  EditorSaveFailure _cancelledFailure() => const EditorSaveFailure(
    EditorSaveFailureType.cancelled,
    'Операция сохранения отменена.',
  );

  String _basename(String path) {
    final separator = path.lastIndexOf('/');
    return separator < 0 ? path : path.substring(separator + 1);
  }

  Future<void> _deletePartQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Preserve the original integrity/cancellation result.
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Preserve the integrity result; reconciliation can handle an orphan.
    }
  }
}

final class _EditorOperation {
  _EditorOperation(this.token);

  final DownloadCancellationToken token;
  final _completion = Completer<void>();

  Future<void> get completion => _completion.future;

  void cancel() => token.cancel();

  void complete() {
    if (!_completion.isCompleted) _completion.complete();
  }
}

final class _EditorSessionScope {
  const _EditorSessionScope({
    required this.session,
    required this.email,
    required this.epoch,
  });

  final CloudSession session;
  final String email;
  final int epoch;
}

enum _EditorOwnershipKind { direct, inherited, onlineOnly }

final class _EditorOwnershipSnapshot {
  const _EditorOwnershipSnapshot._({
    required this.kind,
    required this.path,
    required this.expectedHash,
    this.targetPath,
    this.targetIncarnation,
  });

  const _EditorOwnershipSnapshot.onlineOnly()
    : this._(kind: _EditorOwnershipKind.onlineOnly, path: '', expectedHash: '');

  _EditorOwnershipSnapshot.direct({
    required String path,
    required String expectedHash,
  }) : this._(
         kind: _EditorOwnershipKind.direct,
         path: path,
         expectedHash: expectedHash,
       );

  _EditorOwnershipSnapshot.inherited({
    required String targetPath,
    required String targetIncarnation,
    required String filePath,
    required String expectedHash,
  }) : this._(
         kind: _EditorOwnershipKind.inherited,
         path: filePath,
         expectedHash: expectedHash,
         targetPath: targetPath,
         targetIncarnation: targetIncarnation,
       );

  final _EditorOwnershipKind kind;
  final String path;
  final String expectedHash;
  final String? targetPath;
  final String? targetIncarnation;
}

final class _EditorOwnershipResult {
  const _EditorOwnershipResult({required this.policy, this.failure});

  final EditorOwnershipPolicy policy;
  final EditorSaveFailure? failure;
}

EditorSaveFailure _fromCloudFailure(CloudFailure failure) => EditorSaveFailure(
  switch (failure.type) {
    CloudFailureType.authRequired => EditorSaveFailureType.authRequired,
    CloudFailureType.network => EditorSaveFailureType.network,
    CloudFailureType.timeout => EditorSaveFailureType.timeout,
    CloudFailureType.notFound => EditorSaveFailureType.notFound,
    CloudFailureType.permissionDenied => EditorSaveFailureType.permissionDenied,
    CloudFailureType.invalidResponse => EditorSaveFailureType.invalidResponse,
    CloudFailureType.service => EditorSaveFailureType.service,
  },
  switch (failure.type) {
    CloudFailureType.authRequired => 'Требуется вход в Mail.ru.',
    CloudFailureType.network => 'Нет соединения с Mail.ru.',
    CloudFailureType.timeout => 'Mail.ru не ответил вовремя.',
    CloudFailureType.notFound => 'Удалённый файл недоступен.',
    CloudFailureType.permissionDenied => 'Mail.ru не разрешил эту операцию.',
    CloudFailureType.invalidResponse => 'Mail.ru вернул неизвестный ответ.',
    CloudFailureType.service => 'Mail.ru временно недоступен.',
  },
  statusCode: failure.statusCode,
);

EditorSaveFailure _fromAuthFailure(AuthFailure failure) => EditorSaveFailure(
  switch (failure.type) {
    AuthFailureType.network => EditorSaveFailureType.network,
    AuthFailureType.timeout => EditorSaveFailureType.timeout,
    AuthFailureType.authRequired ||
    AuthFailureType.invalidCredentials => EditorSaveFailureType.authRequired,
    AuthFailureType.invalidResponse => EditorSaveFailureType.invalidResponse,
    AuthFailureType.service ||
    AuthFailureType.secureStorage => EditorSaveFailureType.service,
  },
  switch (failure.type) {
    AuthFailureType.network => 'Нет соединения с Mail.ru.',
    AuthFailureType.authRequired ||
    AuthFailureType.invalidCredentials => 'Требуется вход в Mail.ru.',
    _ => 'Не удалось получить сессию Mail.ru.',
  },
);

EditorSaveFailure _fromWriteFailure(
  CloudWriteFailure failure,
) => EditorSaveFailure(
  switch (failure.type) {
    CloudWriteFailureType.invalidRequest =>
      EditorSaveFailureType.invalidRequest,
    CloudWriteFailureType.cancelled => EditorSaveFailureType.cancelled,
    CloudWriteFailureType.authRequired => EditorSaveFailureType.authRequired,
    CloudWriteFailureType.network => EditorSaveFailureType.network,
    CloudWriteFailureType.timeout => EditorSaveFailureType.timeout,
    CloudWriteFailureType.notFound => EditorSaveFailureType.notFound,
    CloudWriteFailureType.permissionDenied =>
      EditorSaveFailureType.permissionDenied,
    CloudWriteFailureType.exists => EditorSaveFailureType.conflict,
    CloudWriteFailureType.invalidResponse =>
      EditorSaveFailureType.invalidResponse,
    CloudWriteFailureType.integrity => EditorSaveFailureType.integrity,
    CloudWriteFailureType.remoteOutcomeUnknown =>
      EditorSaveFailureType.remoteOutcomeUnknown,
    CloudWriteFailureType.service => EditorSaveFailureType.service,
  },
  switch (failure.type) {
    CloudWriteFailureType.exists => 'Удалённый файл уже существует.',
    CloudWriteFailureType.cancelled => 'Операция сохранения отменена.',
    CloudWriteFailureType.authRequired => 'Требуется вход в Mail.ru.',
    CloudWriteFailureType.network => 'Нет соединения с Mail.ru.',
    CloudWriteFailureType.timeout => 'Mail.ru не ответил вовремя.',
    CloudWriteFailureType.notFound => 'Удалённый файл недоступен.',
    CloudWriteFailureType.permissionDenied =>
      'Mail.ru не разрешил эту операцию.',
    CloudWriteFailureType.integrity =>
      'Проверка загруженного содержимого не пройдена.',
    CloudWriteFailureType.invalidRequest =>
      'Параметры сохранения недействительны.',
    CloudWriteFailureType.invalidResponse =>
      'Mail.ru вернул неизвестный ответ.',
    CloudWriteFailureType.remoteOutcomeUnknown =>
      'Удалённый результат сохранения не удалось подтвердить. Проверьте файл вручную.',
    CloudWriteFailureType.service => 'Mail.ru временно недоступен.',
  },
  statusCode: failure.statusCode,
  mayHaveSaved: failure.mayHaveSaved,
);
