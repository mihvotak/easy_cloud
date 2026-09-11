import '../domain/offline_target.dart';

/// Persistence-agnostic durable ownership and readiness store for recursive
/// offline targets.
///
/// Target rows are account-scoped by the email supplied to each method. An
/// implementation must persist only its derived account key, never the raw
/// email. Paths are canonical remote paths and errors are safe codes.
abstract interface class OfflineTargetIndex {
  /// Inserts the durable target intent, or updates the same incarnation.
  Future<void> upsertTarget(String email, OfflineTargetRecord target);

  Future<OfflineTargetRecord?> getTarget(
    String email,
    String targetPath, {
    String? targetIncarnation,
  });

  Future<List<OfflineTargetRecord>> listTargets(String email);

  /// Inserts or replaces one deterministic frontier row.
  Future<void> upsertFrontier(
    String email,
    OfflineTargetFrontierRecord frontier,
  );

  Future<List<OfflineTargetFrontierRecord>> listFrontier(
    String email,
    String targetPath, {
    String? targetIncarnation,
  });

  /// Atomically claims the next pending folder, or the requested folder.
  /// Returns null when no claimable row exists.
  Future<OfflineTargetFrontierRecord?> claimFrontier(
    String email,
    String targetPath, {
    required String targetIncarnation,
    String? folderPath,
  });

  /// Updates an existing frontier row without changing its deterministic
  /// sequence.
  Future<void> updateFrontier(
    String email,
    OfflineTargetFrontierRecord frontier,
  );

  /// Converts interrupted target/download work to safe retryable states.
  /// Running/planning/waiting targets become queued, scanning folders become
  /// pending, and downloading/verifying memberships become queued. A target
  /// already in [OfflineTargetState.removing] remains removing. When supplied,
  /// [targetIncarnation] scopes every transition so a stale retry cannot
  /// recover a newer enqueue at the same path.
  Future<void> recoverInProgress(
    String email, {
    String? targetPath,
    String? targetIncarnation,
  });

  /// Creates or replaces one file membership of a target.
  Future<void> upsertTargetFile(String email, OfflineTargetFileRecord file);

  /// Returns one existing target membership, or null when either the target or
  /// its membership no longer exists.
  Future<OfflineTargetFileRecord?> getTargetFile(
    String email,
    String targetPath,
    String filePath, {
    String? targetIncarnation,
  });

  /// Returns one deterministic ready membership for [filePath] across the
  /// account's targets. Implementations must ignore removing targets and
  /// memberships without complete, valid metadata. When targets overlap, the
  /// most specific target wins, followed by canonical target path and
  /// incarnation order.
  Future<OfflineTargetFileRecord?> lookupReadyTargetFile(
    String email,
    String filePath,
  );

  Future<List<OfflineTargetFileRecord>> listTargetFiles(
    String email,
    String targetPath, {
    String? targetIncarnation,
  });

  /// Atomically marks an existing target membership ready with authoritative
  /// file metadata. This method never inserts a target or membership and
  /// returns false when either row has disappeared.
  ///
  /// Implementations must preserve the stored target path, file path, name,
  /// and scan id, while replacing the hash, size, mtime, revisions, readiness,
  /// bytes, and error fields with the supplied verified values.
  Future<bool> markTargetFileReady(
    String email, {
    required String targetPath,
    required String filePath,
    required String targetIncarnation,
    required String hash,
    required int size,
    DateTime? modifiedAt,
    String? revision,
    String? globalRevision,
  });

  /// Updates only readiness/progress/error fields of an existing membership.
  /// A nonnegative [total], when supplied by the download transport, replaces
  /// the planned size before [bytesDone] is clamped.
  Future<void> updateTargetFileReadiness(
    String email, {
    required String targetPath,
    required String filePath,
    required String targetIncarnation,
    required OfflineReadiness readiness,
    int? bytesDone,
    int? total,
    String? errorCode,
  });

  /// Removes one target's rows in one transaction. Direct bindings, other
  /// targets, transient references, and content-addressed files are untouched.
  Future<OfflineTargetRemovalResult> removeTarget(
    String email,
    String targetPath, {
    required String targetIncarnation,
  });

  /// Returns whether a direct row or a ready target membership other than the
  /// supplied target incarnation still protects [hash].
  Future<bool> hasHashReferenceOutsideTarget(
    String email,
    String hash, {
    required String targetPath,
    required String targetIncarnation,
  });

  /// Returns one effective state for every requested path. Missing rows are
  /// returned as [OfflineAvailabilitySource.onlineOnly] with idle readiness.
  /// Implementations must use segment-safe path coverage and keep account
  /// isolation.
  Future<Map<String, OfflineAvailabilityState>> lookupEffectiveAvailability(
    String email,
    Iterable<String> paths,
  );
}

/// Optional transactional capability used by conflict-safe editor saves.
///
/// The operation updates only an already-ready membership whose target
/// incarnation, path, and expected old hash still match.  It never creates a
/// target or membership and returns false for a vanished or newer ownership
/// row.
abstract interface class ConditionalOfflineTargetOwnership {
  Future<bool> updateTargetFileIfMatches(
    String email, {
    required String targetPath,
    required String targetIncarnation,
    required String filePath,
    required String expectedHash,
    required String hash,
    required int size,
    DateTime? modifiedAt,
    String? revision,
    String? globalRevision,
  });
}

/// Transactional storage required by [OfflineTargetQueueController].
///
/// The queue never falls back to a sequence of independent writes: target
/// creation and page commits must be atomic with their durable identity.
abstract interface class OfflineTargetQueueStore {
  /// Persists a planning target and its root frontier in one transaction after
  /// performing the segment-safe overlap check in that same transaction.
  Future<void> createTargetWithRootIfNoOverlap(
    String email,
    OfflineTargetRecord target,
    OfflineTargetFrontierRecord root,
  );

  /// Replaces the target lifecycle row without touching its frontier or
  /// memberships.
  Future<void> updateTarget(String email, OfflineTargetRecord target);

  /// Commits one remote page, its accepted memberships/new frontier rows, and
  /// the current frontier offset in one transaction.
  Future<void> commitFrontierPage(
    String email, {
    required OfflineTargetFrontierRecord current,
    required OfflineTargetFrontierRecord updated,
    required Iterable<OfflineTargetFrontierRecord> discoveredFolders,
    required Iterable<OfflineTargetFileRecord> discoveredFiles,
  });
}

/// An enqueue conflicts with an equal or segment-safe nested target.
final class OfflineTargetOverlapException implements Exception {
  const OfflineTargetOverlapException({required this.existingPath});

  final String existingPath;

  @override
  String toString() =>
      'Offline target overlaps an existing target at $existingPath.';
}
