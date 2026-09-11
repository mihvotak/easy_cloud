import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/errors/cloud_failure.dart';
import '../../../local/cache/content_addressed_file_cache.dart';
import '../../browser/application/browser_repository.dart';
import '../../browser/domain/cloud_folder_page.dart';
import '../../browser/domain/cloud_node.dart';
import '../../browser/domain/cloud_sort.dart';
import '../../download/application/download_repository.dart';
import '../../download/domain/download.dart';
import '../domain/offline_target.dart';
import '../domain/offline_target_queue.dart';
import '../domain/offline_file_record.dart';
import 'offline_target_index.dart';

/// Minimal lifecycle boundary for hosts that can expose the authenticated
/// account and its monotonically increasing session epoch.
///
/// Production wiring supplies this adapter. Tests and other foreground hosts
/// may omit it when they provide an equivalent account boundary themselves.
/// When supplied, queue mutations are additionally rejected as soon as the
/// attached account/epoch changes; the download repository remains the hard
/// account boundary for target stat and ownership writes.
abstract interface class AccountEpochProvider {
  String? get currentEmail;

  int get epoch;
}

/// Foreground, durable recursive folder worker.
///
/// The controller owns only the handles returned for target downloads. It
/// never closes the browser or download repository, so it can coexist with
/// the ordinary download/open controllers. Traversal progress is durable in
/// [OfflineTargetIndex]; a new attached controller can therefore recover and
/// continue it after a process restart.
final class OfflineTargetQueueController extends ChangeNotifier {
  OfflineTargetQueueController({
    required OfflineTargetIndex targetIndex,
    required BrowserRepository browserRepository,
    required DownloadRepository downloadRepository,
    required OfflineTargetQueueStore queueStore,
    String Function()? targetIncarnationGenerator,
    AccountEpochProvider? accountEpochProvider,
    DateTime Function()? clock,
  }) : _targetIndex = targetIndex,
       _browserRepository = browserRepository,
       _downloadRepository = downloadRepository,
       _queueStore = queueStore,
       _targetIncarnationGenerator =
           targetIncarnationGenerator ?? _randomTargetIncarnation,
       _accountEpochProvider = accountEpochProvider,
       _clock = clock ?? DateTime.now;

  static const int pageLimit = 100;
  static const int maxConcurrentDownloads = 2;
  static const int _progressByteStep = 256 * 1024;
  static const Duration _progressTimeStep = Duration(milliseconds: 250);
  static final _accountLimiters = <String, _PermitPool>{};

  final OfflineTargetIndex _targetIndex;
  final BrowserRepository _browserRepository;
  final DownloadRepository _downloadRepository;
  final OfflineTargetQueueStore _queueStore;
  final String Function() _targetIncarnationGenerator;
  final AccountEpochProvider? _accountEpochProvider;
  final DateTime Function() _clock;

  final _summariesController =
      StreamController<List<OfflineTargetSummary>>.broadcast(sync: true);
  final _summaries = <String, OfflineTargetSummary>{};
  final _runtimes = <String, _TargetRuntime>{};

  Future<void> _lifecycle = Future<void>.value();
  String? _email;
  int _generation = 0;
  int? _attachedAccountEpoch;
  bool _disposed = false;
  bool _notifierDisposed = false;
  Future<void>? _closeFuture;

  /// Canonical account identity currently attached to this worker.
  String? get email => _email;

  /// Session epoch captured when [email] was attached. A host can use this to
  /// reattach after a same-email sign-in replaces the previous session.
  int? get accountEpoch => _attachedAccountEpoch;

  /// A deterministic path-sorted snapshot suitable for a future UI.
  List<OfflineTargetSummary> get summaries => List.unmodifiable(
    _summaries.values.toList()
      ..sort((left, right) => left.targetPath.compareTo(right.targetPath)),
  );

  Stream<List<OfflineTargetSummary>> get summariesStream =>
      _summariesController.stream;

  OfflineTargetSummary? summaryFor(String targetPath) {
    try {
      return _summaries[normalizeOfflineRemotePath(targetPath)];
    } on ArgumentError {
      return null;
    }
  }

  /// Attaches one account, recovers interrupted rows, and resumes work in
  /// deterministic target-path order.
  Future<void> attach(String email) => _serialize(() async {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty) {
      throw ArgumentError.value(email, 'email', 'Email must not be empty.');
    }
    if (_disposed) return;
    // Attaching is the operation that deliberately adopts a new session
    // epoch, including when the account email is unchanged.
    _ensureProviderAccount(normalizedEmail, allowEpochChange: true);

    await _detachInternal();
    if (_disposed) return;
    final generation = ++_generation;
    _email = normalizedEmail;
    _attachedAccountEpoch = _accountEpochProvider?.epoch;
    await _targetIndex.recoverInProgress(normalizedEmail);
    if (!_isAttached(normalizedEmail, generation)) return;

    await _refreshAll(normalizedEmail, generation: generation);
    final targets = await _targetIndex.listTargets(normalizedEmail);
    targets.sort((left, right) => left.targetPath.compareTo(right.targetPath));
    for (final target in targets) {
      if (!_isAttached(normalizedEmail, generation)) return;
      if (target.state == OfflineTargetState.removing) {
        // A removing row is an idempotent durable intent, not interrupted
        // download work.  Retry the removal itself; never resurrect it into a
        // scan after a crash.
        try {
          await _removeTargetRecord(
            normalizedEmail,
            target,
            generation: generation,
          );
        } catch (_) {
          // Keep the row observable as removing. The attach caller can retry
          // explicitly, and no worker is scheduled for this target.
        }
        continue;
      }
      _scheduleTarget(target.targetPath, target.targetIncarnation, generation);
    }
  });

  /// Detaches without deleting durable work. Active target handles are
  /// cancelled and interrupted rows are returned to retryable states.
  Future<void> detach() => _serialize(_detachInternal);

  /// Alias used by lifecycle owners that call their account reset operation
  /// "reset".
  Future<void> reset() => detach();

  /// Creates one target and its root frontier through the required
  /// [OfflineTargetQueueStore] transaction.
  ///
  /// The optional positional estimate keeps the call compact for browser
  /// actions while still allowing an unknown estimate to be explicit.
  Future<OfflineTargetSummary> enqueue(
    CloudNode folder, [
    OfflineTargetEstimate? estimate,
  ]) => _serialize(() async {
    final email = _requireAttached();
    if (folder.type != CloudNodeType.folder) {
      throw ArgumentError.value(
        folder.type,
        'folder.type',
        'Only folders can be queued for offline use.',
      );
    }
    final targetPath = _canonicalPath(folder.path);
    final targetName = folder.name.trim();
    if (targetName.isEmpty) {
      throw ArgumentError.value(
        folder.name,
        'folder.name',
        'Folder name must not be empty.',
      );
    }

    final suppliedEstimate =
        estimate ?? const OfflineTargetEstimate(hasUnknown: true);
    _validateEstimate(suppliedEstimate);
    final now = _now();
    final targetIncarnation = _newTargetIncarnation();
    final generation = _generation;
    _ensureAttachedGeneration(email, generation);
    final target = OfflineTargetRecord(
      targetPath: targetPath,
      targetIncarnation: targetIncarnation,
      targetName: targetName,
      state: OfflineTargetState.planning,
      scanComplete: false,
      estimateFiles: suppliedEstimate.files,
      estimateBytes: suppliedEstimate.bytes,
      estimateHasUnknown:
          suppliedEstimate.hasUnknown ||
          suppliedEstimate.files == null ||
          suppliedEstimate.bytes == null,
      createdAt: now,
      updatedAt: now,
    );
    final root = OfflineTargetFrontierRecord(
      targetPath: targetPath,
      targetIncarnation: targetIncarnation,
      folderPath: targetPath,
      nextOffset: 0,
      state: OfflineTargetFrontierState.pending,
      sequence: 0,
    );

    await _queueStore.createTargetWithRootIfNoOverlap(email, target, root);
    _ensureAttachedGeneration(email, generation);

    final queued = _copyTarget(
      target,
      state: OfflineTargetState.queued,
      updatedAt: _now(),
    );
    await _putTarget(email, queued);
    _ensureAttachedGeneration(email, generation);
    await _refreshTarget(
      targetPath,
      email: email,
      targetIncarnation: targetIncarnation,
    );
    _ensureAttachedGeneration(email, generation);
    if (_isAttached(email, generation)) {
      _scheduleTarget(targetPath, targetIncarnation, generation);
    }
    return _summaries[targetPath]!;
  });

  /// Explicitly retries one target, or all retryable targets when omitted.
  Future<void> retry([String? targetPath]) => _serialize(() async {
    final email = _requireAttached();
    final generation = _generation;
    _ensureAttachedGeneration(email, generation);
    final paths = <String>[];
    if (targetPath == null) {
      final targets = await _targetIndex.listTargets(email);
      _ensureAttachedGeneration(email, generation);
      paths.addAll(targets.map((target) => target.targetPath));
      paths.sort();
    } else {
      paths.add(_canonicalPath(targetPath));
    }

    for (final path in paths) {
      _ensureAttachedGeneration(email, generation);
      var target = await _targetIndex.getTarget(email, path);
      _ensureAttachedGeneration(email, generation);
      if (target == null) continue;
      final runtime = _runtimes[path];
      if (runtime != null) {
        runtime.cancel();
        await _waitRuntime(runtime);
        _ensureAttachedGeneration(email, generation);
      }
      // A claim is durable before the worker can be cancelled. Recover only
      // after the old incarnation has settled, and bind the transition to
      // the incarnation that was actually selected for this attempt.
      await _targetIndex.recoverInProgress(
        email,
        targetPath: path,
        targetIncarnation: target.targetIncarnation,
      );
      _ensureAttachedGeneration(email, generation);
      target = await _targetIndex.getTarget(
        email,
        path,
        targetIncarnation: target.targetIncarnation,
      );
      _ensureAttachedGeneration(email, generation);
      if (target == null || target.state == OfflineTargetState.removing) {
        continue;
      }
      if (target.state == OfflineTargetState.ready) {
        // The worker also repairs a malformed ready membership. Scheduling
        // a ready target is otherwise a no-op.
        _scheduleTarget(path, target.targetIncarnation, generation);
        continue;
      }
      await _prepareForAttempt(email, target);
      _ensureAttachedGeneration(email, generation);
      await _refreshTarget(
        path,
        email: email,
        targetIncarnation: target.targetIncarnation,
      );
      _ensureAttachedGeneration(email, generation);
      _scheduleTarget(path, target.targetIncarnation, generation);
    }
  });

  /// Cancels a target worker first, then asks the download repository to
  /// remove durable ownership and safely collect unreferenced CAS objects.
  Future<void> remove(String targetPath) => _serialize(() async {
    final email = _requireAttached();
    final normalizedPath = _canonicalPath(targetPath);
    final target = await _targetIndex.getTarget(email, normalizedPath);
    if (target == null) return;
    await _removeTargetRecord(email, target, generation: _generation);
  });

  /// More explicit alias for callers that distinguish target removal from
  /// direct-file removal.
  Future<void> removeTarget(String targetPath) => remove(targetPath);

  Future<void> _removeTargetRecord(
    String email,
    OfflineTargetRecord target, {
    required int generation,
  }) async {
    if (!_isAttached(email, generation)) return;
    final removing = target.state == OfflineTargetState.removing
        ? target
        : _copyTarget(
            target,
            state: OfflineTargetState.removing,
            updatedAt: _now(),
          );
    final runtime = _runtimes[target.targetPath];
    runtime?.cancel();
    _ensureProviderAccount(email);
    if (!identical(removing, target)) await _putTarget(email, removing);
    _ensureProviderAccount(email);
    if (runtime != null) await _waitRuntime(runtime);

    try {
      await _downloadRepository.removeTarget(
        target.targetPath,
        expectedEmail: email,
        targetIncarnation: target.targetIncarnation,
      );
    } catch (_) {
      // The removing row is the durable retry intent. In particular, an auth
      // epoch switch or a filesystem failure must never turn it back into a
      // download target.
      await _refreshTarget(
        target.targetPath,
        email: email,
        targetIncarnation: target.targetIncarnation,
      );
      rethrow;
    }
    _summaries.remove(target.targetPath);
    _publishSummaries();
  }

  void _scheduleTarget(
    String targetPath,
    String targetIncarnation,
    int generation,
  ) {
    if (_disposed || _email == null || generation != _generation) return;
    if (_runtimes.containsKey(targetPath)) return;
    final runtime = _TargetRuntime(
      targetPath: targetPath,
      targetIncarnation: targetIncarnation,
      email: _email!,
      accountEpoch: _attachedAccountEpoch,
      generation: generation,
    );
    _runtimes[targetPath] = runtime;
    runtime.future = _runTarget(runtime);
    unawaited(_watchRuntime(runtime));
  }

  Future<void> _watchRuntime(_TargetRuntime runtime) async {
    try {
      await runtime.future;
    } catch (_) {
      // A worker records durable state for expected failures. A final
      // unexpected persistence failure must not become an unhandled future in
      // a foreground controller; recovery on the next attach remains safe.
    } finally {
      final isCurrentRuntime = identical(
        _runtimes[runtime.targetPath],
        runtime,
      );
      if (isCurrentRuntime) {
        _runtimes.remove(runtime.targetPath);
      }
      await runtime.cancellationToken.close();
    }
  }

  Future<void> _waitRuntime(_TargetRuntime runtime) async {
    try {
      await runtime.future;
    } catch (_) {
      // Detach/dispose must settle all owned jobs even when a persistence
      // failure escaped the worker's normal durable error mapping.
    }
  }

  Future<void> _runTarget(_TargetRuntime runtime) async {
    try {
      _ensureActive(runtime);
      var target = await _targetIndex.getTarget(
        runtime.email,
        runtime.targetPath,
        targetIncarnation: runtime.targetIncarnation,
      );
      _ensureActive(runtime);
      if (target == null || target.state == OfflineTargetState.removing) return;
      if (target.state == OfflineTargetState.ready) {
        final repaired = await _repairInvalidReadyMemberships(runtime, target);
        _ensureActive(runtime);
        if (!repaired) return;
        target = await _targetIndex.getTarget(
          runtime.email,
          runtime.targetPath,
          targetIncarnation: runtime.targetIncarnation,
        );
        _ensureActive(runtime);
        if (target == null || target.state == OfflineTargetState.removing) {
          return;
        }
      }

      await _prepareForAttempt(runtime.email, target, runtime: runtime);
      _ensureActive(runtime);
      target = await _targetIndex.getTarget(
        runtime.email,
        runtime.targetPath,
        targetIncarnation: runtime.targetIncarnation,
      );
      _ensureActive(runtime);
      if (target == null || target.state == OfflineTargetState.removing) return;
      await _putTarget(
        runtime.email,
        _copyTarget(
          target,
          state: OfflineTargetState.running,
          updatedAt: _now(),
        ),
      );

      var frontier = await _targetIndex.listFrontier(
        runtime.email,
        runtime.targetPath,
        targetIncarnation: runtime.targetIncarnation,
      );
      final needsScan =
          !target.scanComplete ||
          frontier.any(
            (folder) =>
                folder.state == OfflineTargetFrontierState.pending ||
                folder.state == OfflineTargetFrontierState.scanning,
          );
      if (needsScan) {
        final scanComplete = await _scanTarget(runtime);
        _ensureActive(runtime);
        if (!scanComplete) return;
        frontier = await _targetIndex.listFrontier(
          runtime.email,
          runtime.targetPath,
          targetIncarnation: runtime.targetIncarnation,
        );
        if (frontier.any(
          (folder) => folder.state != OfflineTargetFrontierState.complete,
        )) {
          return;
        }
        target = await _targetIndex.getTarget(
          runtime.email,
          runtime.targetPath,
          targetIncarnation: runtime.targetIncarnation,
        );
        _ensureActive(runtime);
        if (target == null) return;
        await _putTarget(
          runtime.email,
          _copyTarget(
            target,
            scanComplete: true,
            state: OfflineTargetState.running,
            updatedAt: _now(),
          ),
        );
      }

      await _downloadTarget(runtime);
      _ensureActive(runtime);
      await _reconcileTarget(runtime);
    } on _QueueCancelled {
      // Detach/removal owns the durable recovery transition.
    } catch (error) {
      if (!_isActive(runtime)) return;
      await _handleTargetFailure(runtime, error);
    }
  }

  Future<bool> _scanTarget(_TargetRuntime runtime) async {
    while (true) {
      _ensureActive(runtime);
      final current = await _targetIndex.claimFrontier(
        runtime.email,
        runtime.targetPath,
        targetIncarnation: runtime.targetIncarnation,
      );
      _ensureActive(runtime);
      if (current == null) {
        final frontier = await _targetIndex.listFrontier(
          runtime.email,
          runtime.targetPath,
          targetIncarnation: runtime.targetIncarnation,
        );
        _ensureActive(runtime);
        if (frontier.any(
          (folder) => folder.state == OfflineTargetFrontierState.error,
        )) {
          return false;
        }
        return frontier.isNotEmpty &&
            frontier.every(
              (folder) => folder.state == OfflineTargetFrontierState.complete,
            );
      }

      try {
        await _scanFrontier(runtime, current);
      } on _QueuePaused {
        return false;
      }
    }
  }

  Future<void> _scanFrontier(
    _TargetRuntime runtime,
    OfflineTargetFrontierRecord current,
  ) async {
    CloudFolderPage page;
    try {
      page = await _browserRepository.listFolder(
        current.folderPath,
        offset: current.nextOffset,
        limit: pageLimit,
        sort: CloudSort.nameAscending,
      );
      _ensureActive(runtime);
    } on _QueueCancelled {
      rethrow;
    } on CloudFailure catch (failure) {
      await _pauseFrontier(
        runtime,
        current,
        retryable:
            failure.type == CloudFailureType.network ||
            failure.type == CloudFailureType.timeout ||
            failure.type == CloudFailureType.authRequired,
        errorCode: _cloudErrorCode(failure),
      );
      throw const _QueuePaused();
    } catch (error) {
      await _pauseFrontier(
        runtime,
        current,
        retryable: false,
        errorCode: _safeErrorCode(error),
      );
      throw const _QueuePaused();
    }

    if (page.source == CloudFolderPageSource.cache) {
      // Cached pages are useful for later browser display, but are not an
      // authoritative traversal snapshot. Do not persist children or offset.
      await _pauseFrontier(
        runtime,
        current,
        retryable: true,
        errorCode: 'network',
      );
      throw const _QueuePaused();
    }

    late final _AcceptedPage accepted;
    try {
      accepted = await _validateAndAcceptPage(runtime, current, page);
    } on _QueueCancelled {
      rethrow;
    } on _QueueValidation catch (failure) {
      await _pauseFrontier(
        runtime,
        current,
        retryable: false,
        errorCode: failure.code,
      );
      throw const _QueuePaused();
    }

    _ensureActive(runtime);
    final updated = OfflineTargetFrontierRecord(
      targetPath: current.targetPath,
      targetIncarnation: current.targetIncarnation,
      folderPath: current.folderPath,
      nextOffset: current.nextOffset + accepted.items.length,
      state: accepted.terminal
          ? OfflineTargetFrontierState.complete
          : OfflineTargetFrontierState.pending,
      sequence: current.sequence,
    );
    await _queueStore.commitFrontierPage(
      runtime.email,
      current: current,
      updated: updated,
      discoveredFolders: accepted.folders,
      discoveredFiles: accepted.files,
    );
    _ensureActive(runtime);
    await _refreshTarget(
      current.targetPath,
      email: runtime.email,
      targetIncarnation: runtime.targetIncarnation,
    );
  }

  Future<_AcceptedPage> _validateAndAcceptPage(
    _TargetRuntime runtime,
    OfflineTargetFrontierRecord current,
    CloudFolderPage page,
  ) async {
    if (page.items.length > pageLimit || page.totalCount < 0) {
      throw const _QueueValidation('invalid_response');
    }
    final folderPath = _canonicalPathOrNull(page.folder.path);
    if (folderPath == null ||
        folderPath != current.folderPath ||
        page.folder.type != CloudNodeType.folder ||
        page.folder.name.trim().isEmpty) {
      throw const _QueueValidation('invalid_node');
    }
    final offset = current.nextOffset;
    if (offset > page.totalCount ||
        offset + page.items.length > page.totalCount) {
      throw const _QueueValidation('invalid_response');
    }

    final frontier = await _targetIndex.listFrontier(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    final files = await _targetIndex.listTargetFiles(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    final knownFolders = <String, OfflineTargetFrontierRecord>{
      for (final item in frontier) item.folderPath: item,
    };
    final knownFiles = <String, OfflineTargetFileRecord>{
      for (final item in files) item.filePath: item,
    };
    final pagePaths = <String>{};
    final sortedItems = page.items.toList()..sort(_compareNodesByNameAndPath);
    final folders = <OfflineTargetFrontierRecord>[];
    final acceptedFiles = <OfflineTargetFileRecord>[];
    var nextSequence = frontier.fold<int>(
      -1,
      (value, item) => item.sequence > value ? item.sequence : value,
    );
    var newPaths = 0;

    for (final item in sortedItems) {
      final childPath = _canonicalPathOrNull(item.path);
      if (childPath == null ||
          childPath == '/' ||
          _parentPath(childPath) != current.folderPath ||
          !_pathCovers(runtime.targetPath, childPath) ||
          item.name.trim().isEmpty ||
          !pagePaths.add(childPath)) {
        throw const _QueueValidation('invalid_node');
      }
      if (item.type == CloudNodeType.unknown) {
        throw const _QueueValidation('unknown_node');
      }

      final existingFolder = knownFolders[childPath];
      final existingFile = knownFiles[childPath];
      if (existingFolder != null || existingFile != null) {
        // A path is a durable seen marker. Even if a prior membership is not
        // ready, accepting it again would turn a replayed/cross-page child
        // into a second logical discovery.
        throw const _QueueValidation('duplicate_path');
      }

      if (item.type == CloudNodeType.folder) {
        nextSequence++;
        folders.add(
          OfflineTargetFrontierRecord(
            targetPath: runtime.targetPath,
            targetIncarnation: runtime.targetIncarnation,
            folderPath: childPath,
            nextOffset: 0,
            state: OfflineTargetFrontierState.pending,
            sequence: nextSequence,
          ),
        );
        newPaths++;
        continue;
      }

      final candidate = _fileFromNode(
        runtime.targetPath,
        runtime.targetIncarnation,
        item,
      );
      acceptedFiles.add(candidate);
      newPaths++;
    }

    final boundary = offset + sortedItems.length;
    final terminal = boundary == page.totalCount;
    if (!terminal && sortedItems.length < pageLimit) {
      throw const _QueueValidation('invalid_response');
    }
    if (!terminal && newPaths == 0) {
      throw const _QueueValidation('no_progress');
    }
    return _AcceptedPage(
      items: sortedItems,
      folders: folders,
      files: acceptedFiles,
      terminal: terminal,
    );
  }

  Future<void> _pauseFrontier(
    _TargetRuntime runtime,
    OfflineTargetFrontierRecord current, {
    required bool retryable,
    required String errorCode,
  }) async {
    _ensureActive(runtime);
    final updated = OfflineTargetFrontierRecord(
      targetPath: current.targetPath,
      targetIncarnation: current.targetIncarnation,
      folderPath: current.folderPath,
      nextOffset: current.nextOffset,
      state: retryable
          ? OfflineTargetFrontierState.pending
          : OfflineTargetFrontierState.error,
      sequence: current.sequence,
      errorCode: retryable ? null : errorCode,
    );
    await _targetIndex.updateFrontier(runtime.email, updated);
    _ensureActive(runtime);
    final target = await _targetIndex.getTarget(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    if (target != null) {
      await _putTarget(
        runtime.email,
        _copyTarget(
          target,
          state: OfflineTargetState.waitingNetworkOrError,
          scanComplete: false,
          updatedAt: _now(),
        ),
      );
      _ensureActive(runtime);
    }
    await _refreshTarget(
      runtime.targetPath,
      email: runtime.email,
      targetIncarnation: runtime.targetIncarnation,
    );
  }

  Future<void> _downloadTarget(_TargetRuntime runtime) async {
    _ensureActive(runtime);
    final files = await _targetIndex.listTargetFiles(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    final eligible = <OfflineTargetFileRecord>[];
    for (final file in files) {
      if (file.readiness == OfflineReadiness.ready &&
          !_hasCompleteTargetMetadata(file)) {
        // A malformed ready row must not become a permanent skip. The next
        // target operation will revalidate authoritative metadata online.
        await _targetIndex.updateTargetFileReadiness(
          runtime.email,
          targetPath: file.targetPath,
          filePath: file.filePath,
          targetIncarnation: runtime.targetIncarnation,
          readiness: OfflineReadiness.queued,
          bytesDone: 0,
          errorCode: null,
        );
        _ensureActive(runtime);
        eligible.add(file);
        continue;
      }
      if (file.readiness == OfflineReadiness.queued ||
          file.readiness == OfflineReadiness.error ||
          file.readiness == OfflineReadiness.idle) {
        eligible.add(file);
      }
    }
    eligible.sort((left, right) => left.filePath.compareTo(right.filePath));
    await Future.wait(eligible.map((file) => _downloadFile(runtime, file)));
  }

  Future<void> _downloadFile(
    _TargetRuntime runtime,
    OfflineTargetFileRecord planned,
  ) async {
    final limiter = _accountLimiters.putIfAbsent(
      runtime.email.trim().toLowerCase(),
      () => _PermitPool(maxConcurrentDownloads),
    );
    final release = await limiter.acquire(runtime.cancellationToken);
    try {
      _ensureActive(runtime);
      var membership = await _targetIndex.getTargetFile(
        runtime.email,
        runtime.targetPath,
        planned.filePath,
        targetIncarnation: runtime.targetIncarnation,
      );
      _ensureActive(runtime);
      if (membership == null) {
        return;
      }
      if (membership.readiness == OfflineReadiness.ready) {
        if (_hasCompleteTargetMetadata(membership)) return;
        await _targetIndex.updateTargetFileReadiness(
          runtime.email,
          targetPath: membership.targetPath,
          filePath: membership.filePath,
          targetIncarnation: runtime.targetIncarnation,
          readiness: OfflineReadiness.queued,
          bytesDone: 0,
          errorCode: null,
        );
        _ensureActive(runtime);
        membership = await _targetIndex.getTargetFile(
          runtime.email,
          runtime.targetPath,
          membership.filePath,
          targetIncarnation: runtime.targetIncarnation,
        );
        _ensureActive(runtime);
        if (membership == null) return;
      }
      final node = CloudNode(
        path: membership.filePath,
        name: membership.name,
        type: CloudNodeType.file,
        size: membership.size,
        modifiedAt: membership.modifiedAt,
        hash: membership.hash,
        revision: membership.revision,
        globalRevision: membership.globalRevision,
      );

      late final DownloadHandle handle;
      try {
        handle = _downloadRepository.startTarget(
          node,
          targetPath: runtime.targetPath,
          expectedEmail: runtime.email,
          targetIncarnation: runtime.targetIncarnation,
        );
      } catch (error) {
        // The repository validates the expected account/epoch synchronously.
        // In that case no queue mutation is safe: leave the existing
        // membership for recovery/retry rather than writing under another
        // account's current session.
        if (error is DownloadCancelled ||
            error is DownloadFailure &&
                error.type == DownloadFailureType.authRequired) {
          return;
        }
        await _handleDownloadFailure(runtime, membership, error);
        return;
      }
      runtime.handles[membership.filePath] = handle;
      final progressMembership = membership;
      var progressWrites = Future<void>.value();
      var lastProgressBytes = membership.bytesDone - _progressByteStep;
      var lastProgressAt = _clock().toUtc().subtract(_progressTimeStep);
      var lastProgressTotal = membership.size;
      final subscription = handle.progress.listen((progress) {
        final now = _clock().toUtc();
        final isReceiving = progress.phase == DownloadPhase.receiving;
        final total = _validProgressTotal(progress.total);
        final totalChanged = total != null && total != lastProgressTotal;
        final shouldPersist =
            !isReceiving ||
            totalChanged ||
            progress.bytes - lastProgressBytes >= _progressByteStep ||
            now.difference(lastProgressAt) >= _progressTimeStep;
        if (!shouldPersist) return;
        lastProgressBytes = progress.bytes;
        lastProgressAt = now;
        if (total != null) lastProgressTotal = total;
        final readiness = switch (progress.phase) {
          DownloadPhase.resolving => OfflineReadiness.downloading,
          DownloadPhase.receiving => OfflineReadiness.downloading,
          DownloadPhase.verifying => OfflineReadiness.verifying,
          DownloadPhase.committed => OfflineReadiness.ready,
        };
        progressWrites = progressWrites.then((_) async {
          try {
            await _updateMembership(
              runtime,
              progressMembership,
              readiness: readiness,
              bytesDone: progress.bytes < 0 ? 0 : progress.bytes,
              total: total,
              errorCode: null,
              allowReady: readiness == OfflineReadiness.ready,
            );
          } catch (_) {
            // The target may have been removed while the stream delivered a
            // final event. Its durable deletion is the authoritative result.
          }
        });
      });

      try {
        await handle.result;
        await progressWrites;
        _ensureActive(runtime);
        final after = await _targetIndex.getTargetFile(
          runtime.email,
          runtime.targetPath,
          membership.filePath,
          targetIncarnation: runtime.targetIncarnation,
        );
        _ensureActive(runtime);
        if (after == null) return;
        if (after.readiness != OfflineReadiness.ready) {
          // A conforming startTarget marks ready before completing. A fake or
          // older implementation gets a safe service error rather than a
          // false ready target.
          await _handleDownloadFailure(
            runtime,
            after,
            StateError('Target download did not commit membership.'),
          );
        }
      } catch (error) {
        if (!_isActive(runtime)) throw const _QueueCancelled();
        await _handleDownloadFailure(runtime, membership, error);
      } finally {
        await subscription.cancel();
        runtime.handles.remove(membership.filePath);
      }
    } on _QueueCancelled {
      rethrow;
    } finally {
      release();
    }
  }

  Future<void> _handleDownloadFailure(
    _TargetRuntime runtime,
    OfflineTargetFileRecord membership,
    Object error,
  ) async {
    _ensureActive(runtime);
    if (error is DownloadCancelled || error is _QueueCancelled) {
      await _updateMembership(
        runtime,
        membership,
        readiness: OfflineReadiness.queued,
        bytesDone: membership.bytesDone,
        errorCode: null,
      );
      return;
    }

    final code = _safeErrorCode(error);
    final retryable = _isNetworkError(error);
    await _updateMembership(
      runtime,
      membership,
      readiness: retryable ? OfflineReadiness.queued : OfflineReadiness.error,
      bytesDone: retryable ? membership.bytesDone : membership.bytesDone,
      errorCode: retryable ? null : code,
    );
    final target = await _targetIndex.getTarget(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    if (target == null) return;
    await _putTarget(
      runtime.email,
      _copyTarget(
        target,
        state: retryable
            ? OfflineTargetState.waitingNetworkOrError
            : target.scanComplete
            ? OfflineTargetState.partial
            : OfflineTargetState.waitingNetworkOrError,
        updatedAt: _now(),
      ),
    );
    _ensureActive(runtime);
    await _refreshTarget(
      runtime.targetPath,
      email: runtime.email,
      targetIncarnation: runtime.targetIncarnation,
    );
  }

  Future<void> _updateMembership(
    _TargetRuntime runtime,
    OfflineTargetFileRecord membership, {
    required OfflineReadiness readiness,
    required int bytesDone,
    int? total,
    required String? errorCode,
    bool allowReady = false,
  }) async {
    _ensureActive(runtime);
    if (readiness == OfflineReadiness.ready && !allowReady) return;
    await _targetIndex.updateTargetFileReadiness(
      runtime.email,
      targetPath: membership.targetPath,
      filePath: membership.filePath,
      targetIncarnation: runtime.targetIncarnation,
      readiness: readiness,
      bytesDone: bytesDone < 0 ? 0 : bytesDone,
      total: total,
      errorCode: errorCode,
    );
    _ensureActive(runtime);
    await _refreshTarget(
      runtime.targetPath,
      email: runtime.email,
      targetIncarnation: runtime.targetIncarnation,
    );
  }

  Future<void> _reconcileTarget(_TargetRuntime runtime) async {
    _ensureActive(runtime);
    final target = await _targetIndex.getTarget(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    if (target == null) return;
    final frontier = await _targetIndex.listFrontier(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    final files = await _targetIndex.listTargetFiles(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    final scanComplete =
        frontier.isNotEmpty &&
        frontier.every(
          (folder) => folder.state == OfflineTargetFrontierState.complete,
        );
    final hasFrontierError = frontier.any(
      (folder) => folder.state == OfflineTargetFrontierState.error,
    );
    final hasFileError = files.any(
      (file) => file.readiness == OfflineReadiness.error,
    );
    final allReady = files.every(
      (file) => file.readiness == OfflineReadiness.ready && file.hasValidHash,
    );
    final state = hasFrontierError
        ? OfflineTargetState.waitingNetworkOrError
        : hasFileError && scanComplete
        ? OfflineTargetState.partial
        : scanComplete && allReady
        ? OfflineTargetState.ready
        : target.state == OfflineTargetState.waitingNetworkOrError
        ? OfflineTargetState.waitingNetworkOrError
        : OfflineTargetState.queued;
    await _putTarget(
      runtime.email,
      _copyTarget(
        target,
        scanComplete: scanComplete,
        state: state,
        updatedAt: _now(),
      ),
    );
    _ensureActive(runtime);
    await _refreshTarget(
      runtime.targetPath,
      email: runtime.email,
      targetIncarnation: runtime.targetIncarnation,
    );
  }

  Future<void> _handleTargetFailure(
    _TargetRuntime runtime,
    Object error,
  ) async {
    if (!_isActive(runtime)) return;
    if (error is DownloadCancelled || error is _QueueCancelled) {
      return;
    }
    final target = await _targetIndex.getTarget(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    if (target == null) return;
    await _putTarget(
      runtime.email,
      _copyTarget(
        target,
        state: _isNetworkError(error) || !target.scanComplete
            ? OfflineTargetState.waitingNetworkOrError
            : OfflineTargetState.partial,
        updatedAt: _now(),
      ),
    );
    _ensureActive(runtime);
    await _refreshTarget(
      runtime.targetPath,
      email: runtime.email,
      targetIncarnation: runtime.targetIncarnation,
    );
  }

  Future<void> _prepareForAttempt(
    String email,
    OfflineTargetRecord target, {
    _TargetRuntime? runtime,
  }) async {
    _ensureMutationActive(runtime, email);
    var frontier = await _targetIndex.listFrontier(
      email,
      target.targetPath,
      targetIncarnation: target.targetIncarnation,
    );
    final files = await _targetIndex.listTargetFiles(
      email,
      target.targetPath,
      targetIncarnation: target.targetIncarnation,
    );
    _ensureMutationActive(runtime, email);
    for (final folder in frontier) {
      if (folder.state != OfflineTargetFrontierState.error) continue;
      final pending = OfflineTargetFrontierRecord(
        targetPath: folder.targetPath,
        targetIncarnation: folder.targetIncarnation,
        folderPath: folder.folderPath,
        nextOffset: folder.nextOffset,
        state: OfflineTargetFrontierState.pending,
        sequence: folder.sequence,
      );
      _ensureMutationActive(runtime, email);
      await _targetIndex.updateFrontier(email, pending);
      _ensureMutationActive(runtime, email);
    }
    for (final file in files) {
      if (file.readiness != OfflineReadiness.error) continue;
      _ensureMutationActive(runtime, email);
      await _targetIndex.updateTargetFileReadiness(
        email,
        targetPath: file.targetPath,
        filePath: file.filePath,
        targetIncarnation: file.targetIncarnation,
        readiness: OfflineReadiness.queued,
        bytesDone: 0,
        errorCode: null,
      );
      _ensureMutationActive(runtime, email);
    }
    frontier = await _targetIndex.listFrontier(
      email,
      target.targetPath,
      targetIncarnation: target.targetIncarnation,
    );
    _ensureMutationActive(runtime, email);
    final hasFrontierError = frontier.any(
      (folder) => folder.state == OfflineTargetFrontierState.error,
    );
    final scanComplete = target.scanComplete && !hasFrontierError;
    await _putTarget(
      email,
      _copyTarget(
        target,
        scanComplete: scanComplete,
        state: OfflineTargetState.queued,
        updatedAt: _now(),
      ),
    );
    _ensureMutationActive(runtime, email);
  }

  Future<bool> _repairInvalidReadyMemberships(
    _TargetRuntime runtime,
    OfflineTargetRecord target,
  ) async {
    final files = await _targetIndex.listTargetFiles(
      runtime.email,
      target.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    var repaired = false;
    for (final file in files) {
      if (file.readiness != OfflineReadiness.ready ||
          _hasCompleteTargetMetadata(file)) {
        continue;
      }
      await _targetIndex.updateTargetFileReadiness(
        runtime.email,
        targetPath: file.targetPath,
        filePath: file.filePath,
        targetIncarnation: runtime.targetIncarnation,
        readiness: OfflineReadiness.queued,
        bytesDone: 0,
        errorCode: null,
      );
      _ensureActive(runtime);
      repaired = true;
    }
    if (!repaired) return false;

    final current = await _targetIndex.getTarget(
      runtime.email,
      runtime.targetPath,
      targetIncarnation: runtime.targetIncarnation,
    );
    _ensureActive(runtime);
    if (current == null || current.state == OfflineTargetState.removing) {
      return true;
    }
    await _putTarget(
      runtime.email,
      _copyTarget(current, state: OfflineTargetState.queued, updatedAt: _now()),
    );
    _ensureActive(runtime);
    return true;
  }

  bool _hasCompleteTargetMetadata(OfflineTargetFileRecord file) {
    final size = file.size;
    final hash = file.hash;
    if (size == null || size < 0 || hash == null) return false;
    try {
      normalizeCloudHash(hash);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  Future<void> _detachInternal() async {
    final oldEmail = _email;
    final runtimes = _runtimes.values.toList(growable: false);
    _generation++;
    _email = null;
    _attachedAccountEpoch = null;
    for (final runtime in runtimes) {
      runtime.cancel();
    }
    await Future.wait(runtimes.map(_waitRuntime));
    _runtimes.clear();
    if (oldEmail != null) {
      await _targetIndex.recoverInProgress(oldEmail);
    }
    _summaries.clear();
    _publishSummaries();
  }

  Future<void> _refreshAll(String email, {required int generation}) async {
    final targets = await _targetIndex.listTargets(email);
    if (!_isAttached(email, generation)) return;
    _summaries.clear();
    for (final target in targets) {
      final frontier = await _targetIndex.listFrontier(
        email,
        target.targetPath,
        targetIncarnation: target.targetIncarnation,
      );
      final files = await _targetIndex.listTargetFiles(
        email,
        target.targetPath,
        targetIncarnation: target.targetIncarnation,
      );
      if (!_isAttached(email, generation)) return;
      _summaries[target.targetPath] = OfflineTargetSummary(
        target: target,
        frontier: frontier,
        files: files,
      );
    }
    _publishSummaries();
  }

  Future<void> _refreshTarget(
    String targetPath, {
    required String email,
    required String targetIncarnation,
  }) async {
    if (_disposed || _email != email) return;
    final target = await _targetIndex.getTarget(
      email,
      targetPath,
      targetIncarnation: targetIncarnation,
    );
    if (_disposed || _email != email) return;
    if (target == null) {
      _summaries.remove(targetPath);
    } else {
      final frontier = await _targetIndex.listFrontier(
        email,
        targetPath,
        targetIncarnation: targetIncarnation,
      );
      final files = await _targetIndex.listTargetFiles(
        email,
        targetPath,
        targetIncarnation: targetIncarnation,
      );
      if (_disposed || _email != email) return;
      _summaries[targetPath] = OfflineTargetSummary(
        target: target,
        frontier: frontier,
        files: files,
      );
    }
    _publishSummaries();
  }

  Future<void> _putTarget(String email, OfflineTargetRecord target) async {
    await _queueStore.updateTarget(email, target);
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _lifecycle.then((_) => action());
    _lifecycle = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  String _requireAttached() {
    if (_disposed || _email == null) {
      throw StateError('Offline target queue is not attached.');
    }
    _ensureProviderAccount(_email!);
    return _email!;
  }

  void _ensureAttachedGeneration(String email, int generation) {
    if (!_isAttached(email, generation)) {
      throw StateError('Offline target account or session changed.');
    }
  }

  bool _isAttached(String email, int generation, {int? accountEpoch}) {
    if (_disposed || _email != email || _generation != generation) return false;
    final provider = _accountEpochProvider;
    if (provider == null) return true;
    final expectedEpoch = accountEpoch ?? _attachedAccountEpoch;
    return expectedEpoch != null &&
        provider.epoch == expectedEpoch &&
        _normalizedProviderEmail(provider.currentEmail) == email;
  }

  bool _isActive(_TargetRuntime runtime) =>
      _isAttached(
        runtime.email,
        runtime.generation,
        accountEpoch: runtime.accountEpoch,
      ) &&
      !runtime.cancelled;

  void _ensureActive(_TargetRuntime runtime) {
    if (!_isActive(runtime)) throw const _QueueCancelled();
  }

  void _ensureProviderAccount(
    String expectedEmail, {
    bool allowEpochChange = false,
  }) {
    final provider = _accountEpochProvider;
    if (provider == null) return;
    if (_normalizedProviderEmail(provider.currentEmail) != expectedEmail) {
      throw StateError(
        'Offline target account changed while queue was attached.',
      );
    }
    final attachedEpoch = _attachedAccountEpoch;
    if (!allowEpochChange &&
        attachedEpoch != null &&
        provider.epoch != attachedEpoch) {
      throw StateError('Offline target session epoch changed.');
    }
  }

  void _ensureMutationActive(_TargetRuntime? runtime, String email) {
    if (runtime != null) {
      _ensureActive(runtime);
    } else {
      _ensureProviderAccount(email);
    }
  }

  String? _normalizedProviderEmail(String? email) {
    final normalized = email?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  void _validateEstimate(OfflineTargetEstimate estimate) {
    if (estimate.files != null && estimate.files! < 0) {
      throw ArgumentError.value(estimate.files, 'estimate.files');
    }
    if (estimate.bytes != null && estimate.bytes! < 0) {
      throw ArgumentError.value(estimate.bytes, 'estimate.bytes');
    }
  }

  String _newTargetIncarnation() =>
      normalizeOfflineTargetIncarnation(_targetIncarnationGenerator());

  OfflineTargetFileRecord _fileFromNode(
    String targetPath,
    String targetIncarnation,
    CloudNode node,
  ) {
    final path = _canonicalPathOrNull(node.path);
    if (path == null || !_pathCovers(targetPath, path) || path == targetPath) {
      throw const _QueueValidation('invalid_node');
    }
    if (node.type != CloudNodeType.file || node.name.trim().isEmpty) {
      throw const _QueueValidation('unknown_node');
    }
    if (node.size != null && node.size! < 0) {
      throw const _QueueValidation('invalid_node');
    }
    String? hash;
    if (node.hash != null) {
      try {
        hash = normalizeCloudHash(node.hash!);
      } on ArgumentError {
        throw const _QueueValidation('invalid_metadata');
      }
    }
    return OfflineTargetFileRecord(
      targetPath: targetPath,
      targetIncarnation: targetIncarnation,
      filePath: path,
      name: node.name,
      hash: hash,
      size: node.size,
      modifiedAt: node.modifiedAt,
      revision: node.revision,
      globalRevision: node.globalRevision,
      readiness: OfflineReadiness.queued,
      bytesDone: 0,
      updatedAt: _now(),
    );
  }

  OfflineTargetRecord _copyTarget(
    OfflineTargetRecord target, {
    OfflineTargetState? state,
    bool? scanComplete,
    DateTime? updatedAt,
  }) => OfflineTargetRecord(
    targetPath: target.targetPath,
    targetIncarnation: target.targetIncarnation,
    targetName: target.targetName,
    state: state ?? target.state,
    scanComplete: scanComplete ?? target.scanComplete,
    estimateFiles: target.estimateFiles,
    estimateBytes: target.estimateBytes,
    estimateHasUnknown: target.estimateHasUnknown,
    createdAt: target.createdAt,
    updatedAt: updatedAt ?? target.updatedAt,
  );

  int? _validProgressTotal(int? value) =>
      value == null || value < 0 ? null : value;

  DateTime _now() => _clock().toUtc();

  String _canonicalPath(String path) {
    try {
      return normalizeOfflineRemotePath(path);
    } on ArgumentError {
      throw ArgumentError.value(path, 'path', 'Invalid remote path.');
    }
  }

  String? _canonicalPathOrNull(String path) {
    try {
      return normalizeOfflineRemotePath(path);
    } on ArgumentError {
      return null;
    }
  }

  bool _pathCovers(String parent, String path) => parent == '/'
      ? path.startsWith('/')
      : path == parent || path.startsWith('$parent/');

  String _parentPath(String path) {
    final separator = path.lastIndexOf('/');
    return separator <= 0 ? '/' : path.substring(0, separator);
  }

  int _compareNodesByNameAndPath(CloudNode left, CloudNode right) {
    final byName = left.name.compareTo(right.name);
    return byName == 0 ? left.path.compareTo(right.path) : byName;
  }

  bool _isNetworkError(Object error) => switch (error) {
    DownloadFailure failure =>
      failure.type == DownloadFailureType.network ||
          failure.type == DownloadFailureType.timeout ||
          failure.type == DownloadFailureType.authRequired,
    CloudFailure failure =>
      failure.type == CloudFailureType.network ||
          failure.type == CloudFailureType.timeout ||
          failure.type == CloudFailureType.authRequired,
    _ => false,
  };

  String _cloudErrorCode(CloudFailure failure) => switch (failure.type) {
    CloudFailureType.network => 'network',
    CloudFailureType.timeout => 'timeout',
    CloudFailureType.authRequired => 'auth_required',
    CloudFailureType.notFound => 'not_found',
    CloudFailureType.permissionDenied => 'permission_denied',
    CloudFailureType.invalidResponse => 'invalid_response',
    CloudFailureType.service => 'service',
  };

  String _safeErrorCode(Object error) => switch (error) {
    _QueueValidation failure => failure.code,
    DownloadFailure failure => switch (failure.type) {
      DownloadFailureType.authRequired => 'auth_required',
      DownloadFailureType.network => 'network',
      DownloadFailureType.timeout => 'timeout',
      DownloadFailureType.service => 'service',
      DownloadFailureType.notFound => 'not_found',
      DownloadFailureType.permissionDenied => 'permission_denied',
      DownloadFailureType.invalidResponse => 'invalid_response',
      DownloadFailureType.disk => 'disk',
      DownloadFailureType.cancelled => 'cancelled',
      DownloadFailureType.integrity => 'integrity',
    },
    CloudFailure failure => _cloudErrorCode(failure),
    ArgumentError() => 'invalid_response',
    FormatException() => 'invalid_response',
    _ => 'service',
  };

  void _publishSummaries() {
    if (_disposed) return;
    final snapshot = summaries;
    if (!_summariesController.isClosed) _summariesController.add(snapshot);
    notifyListeners();
  }

  /// Closes the queue after all serialized mutations and target runtimes have
  /// settled.  The caller must await this before closing the shared download
  /// repository, browser repository, or SQLite index.
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;

    final oldEmail = _email;
    final runtimes = _runtimes.values.toList(growable: false);
    _disposed = true;
    _generation++;
    _email = null;
    _attachedAccountEpoch = null;
    for (final runtime in runtimes) {
      runtime.cancel();
    }

    final closing = _finishClose(oldEmail, runtimes);
    _closeFuture = closing;
    return closing;
  }

  Future<void> _finishClose(
    String? oldEmail,
    List<_TargetRuntime> runtimes,
  ) async {
    // A queued enqueue/remove must finish (or observe the closed generation)
    // before the storage owner is allowed to close.  Errors are already
    // delivered to their callers; shutdown itself remains best-effort and
    // never leaks an unhandled future from a widget dispose boundary.
    try {
      await _lifecycle;
    } catch (_) {
      // The serialized tail deliberately records errors for its caller while
      // still allowing shutdown to continue.
    }
    await Future.wait(runtimes.map(_waitRuntime), eagerError: false);
    _runtimes.clear();

    if (oldEmail != null) {
      try {
        await _targetIndex.recoverInProgress(oldEmail);
      } catch (_) {
        // The index owner decides whether a failed recovery is observable. It
        // is more important here that no queue worker can touch it later.
      }
    }
    _summaries.clear();
    if (!_summariesController.isClosed) {
      await _summariesController.close();
    }
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    unawaited(close().catchError((_) {}));
    super.dispose();
  }
}

String _randomTargetIncarnation() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

final class _TargetRuntime {
  _TargetRuntime({
    required this.targetPath,
    required this.targetIncarnation,
    required this.email,
    required this.accountEpoch,
    required this.generation,
  });

  final String targetPath;
  final String targetIncarnation;
  final String email;
  final int? accountEpoch;
  final int generation;
  final handles = <String, DownloadHandle>{};
  late Future<void> future;
  bool cancelled = false;

  DownloadCancellationToken get cancellationToken => _cancellationToken;

  final DownloadCancellationToken _cancellationToken =
      DownloadCancellationToken();

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _cancellationToken.cancel();
    for (final handle in handles.values.toList(growable: false)) {
      handle.cancel();
    }
  }
}

final class _AcceptedPage {
  const _AcceptedPage({
    required this.items,
    required this.folders,
    required this.files,
    required this.terminal,
  });

  final List<CloudNode> items;
  final List<OfflineTargetFrontierRecord> folders;
  final List<OfflineTargetFileRecord> files;
  final bool terminal;
}

final class _QueueValidation implements Exception {
  const _QueueValidation(this.code);

  final String code;
}

final class _QueuePaused implements Exception {
  const _QueuePaused();
}

final class _QueueCancelled implements Exception {
  const _QueueCancelled();
}

final class _PermitPool {
  _PermitPool(this._capacity) : _available = _capacity;

  final int _capacity;
  int _available;
  final _waiters = <_PermitWaiter>[];

  Future<Future<void> Function()> acquire([
    DownloadCancellationToken? cancellation,
  ]) async {
    cancellation?.throwIfCancelled();
    if (_available > 0) {
      _available--;
      var released = false;
      return () {
        if (released) return Future<void>.value();
        released = true;
        _release();
        return Future<void>.value();
      };
    }
    final waiter = _PermitWaiter();
    _waiters.add(waiter);
    StreamSubscription<void>? subscription;
    if (cancellation != null) {
      subscription = cancellation.cancellations.listen((_) {
        if (waiter.completed || !_waiters.remove(waiter)) return;
        waiter.completed = true;
        waiter.completer.completeError(const DownloadCancelled());
      });
    }
    try {
      await waiter.completer.future;
      cancellation?.throwIfCancelled();
      waiter.acquired = true;
      var released = false;
      return () {
        if (released) return Future<void>.value();
        released = true;
        _release();
        return Future<void>.value();
      };
    } finally {
      await subscription?.cancel();
      // Cancellation can race with the hand-off that completed the waiter.
      // Return a permit that was granted but never handed to the caller, or a
      // cancelled waiter can permanently reduce this account's concurrency.
      if (waiter.permitGranted && !waiter.acquired) _release();
    }
  }

  void _release() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (waiter.completed) continue;
      waiter.completed = true;
      waiter.permitGranted = true;
      waiter.completer.complete();
      return;
    }
    if (_available < _capacity) _available++;
  }
}

final class _PermitWaiter {
  final completer = Completer<void>();
  bool completed = false;
  bool permitGranted = false;
  bool acquired = false;
}
