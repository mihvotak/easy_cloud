import '../../../local/cache/content_addressed_file_cache.dart';
import 'offline_file_record.dart';

/// Durable lifecycle of a recursive offline target.
enum OfflineTargetState {
  planning,
  queued,
  running,
  waitingNetworkOrError,
  partial,
  ready,
  removing,
}

/// Durable lifecycle of one folder in an offline target frontier.
enum OfflineTargetFrontierState { pending, scanning, complete, error }

/// Readiness is deliberately independent from [OfflineTargetState].
enum OfflineReadiness { idle, queued, downloading, verifying, ready, error }

/// Ownership source used by the effective availability policy.
enum OfflineAvailabilitySource { onlineOnly, direct, directTarget, inherited }

/// A durable recursive offline-download intent.
final class OfflineTargetRecord {
  OfflineTargetRecord({
    required String targetPath,
    required String targetIncarnation,
    required this.targetName,
    required this.state,
    required this.scanComplete,
    this.estimateFiles,
    this.estimateBytes,
    required this.estimateHasUnknown,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) : targetPath = normalizeOfflineRemotePath(targetPath),
       targetIncarnation = normalizeOfflineTargetIncarnation(targetIncarnation),
       createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc() {
    if (targetName.trim().isEmpty) {
      throw ArgumentError.value(
        targetName,
        'targetName',
        'Target name must not be empty.',
      );
    }
    if (estimateFiles != null && estimateFiles! < 0) {
      throw ArgumentError.value(
        estimateFiles,
        'estimateFiles',
        'Estimated file count must be nonnegative.',
      );
    }
    if (estimateBytes != null && estimateBytes! < 0) {
      throw ArgumentError.value(
        estimateBytes,
        'estimateBytes',
        'Estimated byte count must be nonnegative.',
      );
    }
  }

  final String targetPath;

  /// Opaque identity of this particular enqueue of [targetPath].
  ///
  /// A path can be removed and enqueued again while an old asynchronous
  /// operation is still settling.  Every durable target child and every
  /// conditional mutation carries this value so that the old operation cannot
  /// touch the new incarnation.
  final String targetIncarnation;
  final String targetName;
  final OfflineTargetState state;
  final bool scanComplete;
  final int? estimateFiles;
  final int? estimateBytes;
  final bool estimateHasUnknown;
  final DateTime createdAt;
  final DateTime updatedAt;

  @override
  bool operator ==(Object other) =>
      other is OfflineTargetRecord &&
      other.targetPath == targetPath &&
      other.targetIncarnation == targetIncarnation &&
      other.targetName == targetName &&
      other.state == state &&
      other.scanComplete == scanComplete &&
      other.estimateFiles == estimateFiles &&
      other.estimateBytes == estimateBytes &&
      other.estimateHasUnknown == estimateHasUnknown &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    targetPath,
    targetIncarnation,
    targetName,
    state,
    scanComplete,
    estimateFiles,
    estimateBytes,
    estimateHasUnknown,
    createdAt,
    updatedAt,
  );
}

/// One folder in the deterministic traversal frontier of a target.
final class OfflineTargetFrontierRecord {
  OfflineTargetFrontierRecord({
    required String targetPath,
    required String targetIncarnation,
    required String folderPath,
    required this.nextOffset,
    required this.state,
    required this.sequence,
    String? errorCode,
  }) : targetPath = normalizeOfflineRemotePath(targetPath),
       targetIncarnation = normalizeOfflineTargetIncarnation(targetIncarnation),
       folderPath = normalizeOfflineRemotePath(folderPath),
       errorCode = normalizeOfflineErrorCode(errorCode) {
    if (!_pathCovers(this.targetPath, this.folderPath)) {
      throw ArgumentError.value(
        folderPath,
        'folderPath',
        'A frontier folder must belong to its target.',
      );
    }
    if (nextOffset < 0) {
      throw ArgumentError.value(
        nextOffset,
        'nextOffset',
        'Frontier offset must be nonnegative.',
      );
    }
    if (sequence < 0) {
      throw ArgumentError.value(
        sequence,
        'sequence',
        'Frontier sequence must be nonnegative.',
      );
    }
  }

  final String targetPath;
  final String targetIncarnation;
  final String folderPath;
  final int nextOffset;
  final OfflineTargetFrontierState state;
  final int sequence;
  final String? errorCode;

  @override
  bool operator ==(Object other) =>
      other is OfflineTargetFrontierRecord &&
      other.targetPath == targetPath &&
      other.targetIncarnation == targetIncarnation &&
      other.folderPath == folderPath &&
      other.nextOffset == nextOffset &&
      other.state == state &&
      other.sequence == sequence &&
      other.errorCode == errorCode;

  @override
  int get hashCode => Object.hash(
    targetPath,
    targetIncarnation,
    folderPath,
    nextOffset,
    state,
    sequence,
    errorCode,
  );
}

/// Durable membership of a remote file in one target.
final class OfflineTargetFileRecord {
  OfflineTargetFileRecord({
    required String targetPath,
    required String targetIncarnation,
    required String filePath,
    required this.name,
    String? hash,
    this.size,
    DateTime? modifiedAt,
    this.revision,
    this.globalRevision,
    required this.readiness,
    required this.bytesDone,
    String? errorCode,
    this.lastSeenScanId,
    required DateTime updatedAt,
  }) : targetPath = normalizeOfflineRemotePath(targetPath),
       targetIncarnation = normalizeOfflineTargetIncarnation(targetIncarnation),
       filePath = normalizeOfflineRemotePath(filePath),
       hash = hash == null ? null : normalizeCloudHash(hash),
       modifiedAt = modifiedAt?.toUtc(),
       errorCode = normalizeOfflineErrorCode(errorCode),
       updatedAt = updatedAt.toUtc() {
    if (!_pathCovers(this.targetPath, this.filePath)) {
      throw ArgumentError.value(
        filePath,
        'filePath',
        'A target file must belong to its target.',
      );
    }
    if (this.filePath == '/') {
      throw ArgumentError.value(
        filePath,
        'filePath',
        'A target file path is required.',
      );
    }
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'File name must not be empty.');
    }
    if (size != null && size! < 0) {
      throw ArgumentError.value(size, 'size', 'Size must be nonnegative.');
    }
    if (bytesDone < 0) {
      throw ArgumentError.value(
        bytesDone,
        'bytesDone',
        'Downloaded bytes must be nonnegative.',
      );
    }
    if (size != null && bytesDone > size!) {
      throw ArgumentError.value(
        bytesDone,
        'bytesDone',
        'Downloaded bytes cannot exceed the file size.',
      );
    }
    if (lastSeenScanId != null && lastSeenScanId! < 0) {
      throw ArgumentError.value(
        lastSeenScanId,
        'lastSeenScanId',
        'Scan id must be nonnegative.',
      );
    }
  }

  final String targetPath;
  final String targetIncarnation;
  final String filePath;
  final String name;
  final String? hash;
  final int? size;
  final DateTime? modifiedAt;
  final String? revision;
  final String? globalRevision;
  final OfflineReadiness readiness;
  final int bytesDone;
  final String? errorCode;
  final int? lastSeenScanId;
  final DateTime updatedAt;

  /// A ready row without a valid hash is not sufficient proof of ownership.
  bool get hasValidHash => hash != null;

  @override
  bool operator ==(Object other) =>
      other is OfflineTargetFileRecord &&
      other.targetPath == targetPath &&
      other.targetIncarnation == targetIncarnation &&
      other.filePath == filePath &&
      other.name == name &&
      other.hash == hash &&
      other.size == size &&
      other.modifiedAt == modifiedAt &&
      other.revision == revision &&
      other.globalRevision == globalRevision &&
      other.readiness == readiness &&
      other.bytesDone == bytesDone &&
      other.errorCode == errorCode &&
      other.lastSeenScanId == lastSeenScanId &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    targetPath,
    targetIncarnation,
    filePath,
    name,
    hash,
    size,
    modifiedAt,
    revision,
    globalRevision,
    readiness,
    bytesDone,
    errorCode,
    lastSeenScanId,
    updatedAt,
  );
}

/// Effective availability for one visible remote path.
final class OfflineAvailabilityState {
  OfflineAvailabilityState({
    required String path,
    required this.source,
    required this.readiness,
    this.targetPath,
    this.directRecord,
    this.targetFile,
  }) : path = normalizeOfflineRemotePath(path);

  final String path;
  final OfflineAvailabilitySource source;
  final OfflineReadiness readiness;
  final String? targetPath;
  final OfflineFileRecord? directRecord;
  final OfflineTargetFileRecord? targetFile;

  bool get isReady => readiness == OfflineReadiness.ready;

  @override
  bool operator ==(Object other) =>
      other is OfflineAvailabilityState &&
      other.path == path &&
      other.source == source &&
      other.readiness == readiness &&
      other.targetPath == targetPath &&
      other.directRecord == directRecord &&
      other.targetFile == targetFile;

  @override
  int get hashCode => Object.hash(
    path,
    source,
    readiness,
    targetPath,
    directRecord,
    targetFile,
  );
}

/// Information returned after one target's ownership rows are removed.
///
/// SQLite never deletes a content-addressed object. The released hashes and
/// the remaining durable reference counts are returned so a later cache/GC
/// layer can make that decision without losing information.
final class OfflineTargetRemovalResult {
  OfflineTargetRemovalResult({
    required this.target,
    required Iterable<OfflineTargetFileRecord> removedFiles,
    required Iterable<String> releasedHashes,
    required Map<String, int> remainingReferences,
  }) : removedFiles = List.unmodifiable(removedFiles),
       releasedHashes = Set.unmodifiable(releasedHashes),
       remainingReferences = Map.unmodifiable(remainingReferences);

  final OfflineTargetRecord? target;
  final List<OfflineTargetFileRecord> removedFiles;
  final Set<String> releasedHashes;
  final Map<String, int> remainingReferences;

  bool get removed => target != null;
}

/// Error values persisted by target rows are codes, never backend messages.
String? normalizeOfflineErrorCode(String? errorCode) {
  if (errorCode == null) return null;
  final normalized = errorCode.trim().toLowerCase();
  if (!RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(normalized)) {
    throw ArgumentError.value(
      errorCode,
      'errorCode',
      'Error code must be a short lowercase safe code.',
    );
  }
  return normalized;
}

/// Validates the opaque identity of one durable target incarnation.
///
/// The queue normally supplies a cryptographically random value.  The
/// restricted alphabet keeps the value safe for SQLite rows and deterministic
/// migration values without assigning it any semantic meaning.
String normalizeOfflineTargetIncarnation(String value) {
  if (value.isEmpty ||
      value.trim() != value ||
      !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
    throw ArgumentError.value(
      value,
      'targetIncarnation',
      'Target incarnation must be a non-empty opaque safe string.',
    );
  }
  return value;
}

bool _pathCovers(String parent, String path) =>
    parent == '/' || path == parent || path.startsWith('$parent/');
