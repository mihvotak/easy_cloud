import 'dart:async';

import '../../features/download/domain/download_cancellation.dart';
import '../../features/download/domain/download_failure.dart';

/// The only lock order permitted for app-local cloud mutations.
///
/// A target lock may cover several paths, and a path lock may cover several
/// hashes.  Locks of the same kind must be acquired in deterministic key order
/// when more than one is needed.  [CloudCacheCoordinator] checks the order for
/// every cancellation token, so accidentally acquiring a broader lock after a
/// narrower one fails instead of creating an async deadlock.
enum CloudCacheLockKind { account, target, path, hash }

String cloudCacheAccountKey(String accountKey) => 'account:$accountKey';

String cloudCacheTargetKey(String accountKey, String canonicalPath) =>
    '$accountKey:target:$canonicalPath';

String cloudCachePathKey(String accountKey, String canonicalPath) =>
    '$accountKey:path:$canonicalPath';

String cloudCacheHashKey(String accountKey, String hash) =>
    '$accountKey:hash:$hash';

/// Serializes mutations of one account-scoped content-addressed object.
///
/// The coordinator deliberately knows nothing about files or SQLite.  Callers
/// use an account-qualified key (normally `<account-cache-key>:<HASH>`) and
/// keep the returned release callback until the complete read/write/ownership
/// hand-off has settled.  Waiting is cancellation-aware, so a cancelled
/// operation is removed from the queue without allowing a later waiter to
/// bypass the operation that was in front of it.
///
/// One instance must be shared by every repository which can touch a CAS
/// object.  This is what makes editor saves, downloads, removals, and
/// reconciliation mutually exclusive for the same account and hash.
final class CloudCacheCoordinator {
  final _tails = <String, _CloudCacheCoordinatorGate>{};
  final _heldLocks = <DownloadCancellationToken, List<_HeldCloudCacheLock>>{};
  Future<void>? _closeFuture;
  bool _closed = false;

  /// Acquires [key] in FIFO order and returns an idempotent release callback.
  ///
  /// If a waiter is cancelled, its gate is a tombstone: it remains closed
  /// until its predecessor releases.  Opening that gate immediately would let
  /// a later waiter skip an active predecessor (A -> B -> C, with B cancelled).
  Future<void Function()> acquire(
    String key,
    DownloadCancellationToken cancellation, {
    CloudCacheLockKind kind = CloudCacheLockKind.hash,
  }) async {
    if (_closed) throw StateError('Cloud cache coordinator is closed.');
    if (key.isEmpty) throw ArgumentError.value(key, 'key');
    _ensureLockOrder(cancellation, kind, key);

    final previous = _tails[key];
    final gate = _CloudCacheCoordinatorGate();
    _tails[key] = gate;
    try {
      await _waitForTurn(previous?.future, cancellation);
      if (_closed) throw StateError('Cloud cache coordinator is closed.');
      cancellation.throwIfCancelled();
    } catch (_) {
      _tombstone(key, gate, previous);
      rethrow;
    }

    _markHeld(cancellation, kind, key);
    var released = false;
    return () {
      if (released) return;
      released = true;
      _markReleased(cancellation, kind, key);
      gate.open();
      if (identical(_tails[key], gate)) _tails.remove(key);
    };
  }

  /// Prevents new acquisitions and waits for already queued owners.
  ///
  /// Repositories normally own operation cancellation and call this method
  /// only after their active operations have settled.  Keeping the method
  /// awaitable also makes a directly-owned coordinator safe to shut down.
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    final pending = _tails.values
        .map((gate) => gate.future)
        .toList(growable: false);
    final closing = Future.wait(pending, eagerError: false).then<void>((_) {});
    _closeFuture = closing;
    return closing;
  }

  Future<void> _waitForTurn(
    Future<void>? previous,
    DownloadCancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (previous == null) return;

    final settled = Completer<void>();
    var completed = false;

    void complete() {
      if (completed) return;
      completed = true;
      settled.complete();
    }

    void completeError(Object error, StackTrace stackTrace) {
      if (completed) return;
      completed = true;
      settled.completeError(error, stackTrace);
    }

    final subscription = cancellation.cancellations.listen((_) {
      completeError(const DownloadCancelled(), StackTrace.current);
    });
    unawaited(
      previous.then<void>(
        (_) => complete(),
        onError: (Object error, StackTrace stackTrace) {
          completeError(error, stackTrace);
        },
      ),
    );

    try {
      await settled.future;
    } finally {
      await subscription.cancel();
    }
  }

  void _ensureLockOrder(
    DownloadCancellationToken cancellation,
    CloudCacheLockKind requested,
    String key,
  ) {
    final held = _heldLocks[cancellation];
    if (held == null || held.isEmpty) return;
    for (final lock in held) {
      if (requested.index < lock.kind.index ||
          (requested == lock.kind && key.compareTo(lock.key) < 0)) {
        throw StateError(
          'Cloud cache locks must be acquired in account/target/path/hash '
          'and key order.',
        );
      }
    }
  }

  void _markHeld(
    DownloadCancellationToken cancellation,
    CloudCacheLockKind kind,
    String key,
  ) {
    _heldLocks
        .putIfAbsent(cancellation, () => [])
        .add(_HeldCloudCacheLock(kind: kind, key: key));
  }

  void _markReleased(
    DownloadCancellationToken cancellation,
    CloudCacheLockKind kind,
    String key,
  ) {
    final held = _heldLocks[cancellation];
    if (held == null) return;
    final index = held.lastIndexWhere(
      (lock) => lock.kind == kind && lock.key == key,
    );
    if (index >= 0) held.removeAt(index);
    if (held.isEmpty) _heldLocks.remove(cancellation);
  }

  void _tombstone(
    String key,
    _CloudCacheCoordinatorGate gate,
    _CloudCacheCoordinatorGate? previous,
  ) {
    // Do not open a cancelled waiter's gate while its predecessor is active.
    // The successor may already be waiting on this exact gate.
    void openAfterPredecessor() {
      gate.open();
      if (identical(_tails[key], gate)) _tails.remove(key);
    }

    if (previous == null || previous.isOpen) {
      openAfterPredecessor();
      return;
    }
    unawaited(
      previous.future.then<void>(
        (_) => openAfterPredecessor(),
        onError: (Object error, StackTrace stackTrace) {
          openAfterPredecessor();
        },
      ),
    );
  }
}

final class _HeldCloudCacheLock {
  const _HeldCloudCacheLock({required this.kind, required this.key});

  final CloudCacheLockKind kind;
  final String key;
}

final class _CloudCacheCoordinatorGate {
  final _completer = Completer<void>();
  bool isOpen = false;

  Future<void> get future => _completer.future;

  void open() {
    if (isOpen) return;
    isOpen = true;
    _completer.complete();
  }
}
