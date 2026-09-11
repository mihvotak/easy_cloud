import '../../../features/download/domain/download_cancellation.dart';
import '../../../local/cache/content_addressed_file_cache.dart';

/// Maximum content size accepted by the text-editor save service.
const editorMaxBytes = 10485760;

/// Cancellation supplied by an application boundary.
///
/// The service never creates or persists auth tokens in this object.  It is an
/// alias of the existing cancellation primitive so download and editor
/// operations can be cancelled by the same lifecycle owner.
typedef EditorSaveCancellation = DownloadCancellationToken;

/// How a save should resolve a remote path conflict.
enum EditorSaveChoice { unchanged, overwrite, copy }

/// Observable stages of one save operation.
enum EditorSavePhase {
  checkingConflict,
  hashing,
  preparingCache,
  resolvingShard,
  uploading,
  registering,
  verifyingRemote,
  committingOwnership,
  completed,
}

/// Safe, presentation-independent failure categories returned by the editor
/// service and its write transport.
enum EditorSaveFailureType {
  invalidRequest,
  cancelled,
  authRequired,
  network,
  timeout,
  notFound,
  permissionDenied,
  conflict,
  integrity,
  invalidResponse,
  service,
  disk,
  partialSuccess,

  /// Registration reached the server, but the client could not prove the
  /// resulting remote object.  This is deliberately not retryable: the
  /// remote side may already contain the new contents.
  remoteOutcomeUnknown,
}

/// The local ownership policy captured before a save began.
enum EditorOwnershipPolicy {
  direct,
  inherited,
  onlineOnly,
  copy,
  fallbackTransient,
}

/// Type exposed by the editor domain rather than the backend response model.
enum EditorRemoteNodeType { file, folder, unknown }

/// Metadata captured by the editor when it opens a file.
///
/// [path] and [canonicalPath] are accepted as synonyms to keep the model
/// convenient for both repository and editor callers.  The stored value is
/// always canonical and never includes a local filesystem path.
final class EditorSaveBaseline {
  factory EditorSaveBaseline({
    String? path,
    String? canonicalPath,
    required String hash,
    required int size,
    DateTime? modifiedAt,
    DateTime? mtime,
    String? revision,
    String? rev,
    String? globalRevision,
    String? grev,
  }) {
    final selectedPath = canonicalPath ?? path;
    if (selectedPath == null) {
      throw ArgumentError('A canonical remote path is required.');
    }
    if (path != null && canonicalPath != null && path != canonicalPath) {
      throw ArgumentError('Baseline paths do not match.');
    }
    if (size < 0) {
      throw ArgumentError.value(size, 'size', 'Size must be nonnegative.');
    }
    final normalizedPath = normalizeEditorPath(selectedPath);
    if (normalizedPath == '/') {
      throw ArgumentError.value(
        selectedPath,
        'path',
        'A file path is required.',
      );
    }
    final selectedModifiedAt = modifiedAt ?? mtime;
    if (modifiedAt != null && mtime != null && modifiedAt != mtime) {
      throw ArgumentError('Baseline modification times do not match.');
    }
    final selectedRevision = revision ?? rev;
    if (revision != null && rev != null && revision != rev) {
      throw ArgumentError('Baseline revisions do not match.');
    }
    final selectedGlobalRevision = globalRevision ?? grev;
    if (globalRevision != null && grev != null && globalRevision != grev) {
      throw ArgumentError('Baseline global revisions do not match.');
    }
    return EditorSaveBaseline._(
      path: normalizedPath,
      hash: normalizeCloudHash(hash),
      size: size,
      modifiedAt: selectedModifiedAt?.toUtc(),
      revision: selectedRevision,
      globalRevision: selectedGlobalRevision,
    );
  }

  const EditorSaveBaseline._({
    required this.path,
    required this.hash,
    required this.size,
    required this.modifiedAt,
    required this.revision,
    required this.globalRevision,
  });

  final String path;
  final String hash;
  final int size;
  final DateTime? modifiedAt;
  final String? revision;
  final String? globalRevision;

  String get canonicalPath => path;
  DateTime? get mtime => modifiedAt;
  String? get rev => revision;
  String? get grev => globalRevision;

  @override
  bool operator ==(Object other) =>
      other is EditorSaveBaseline &&
      other.path == path &&
      other.hash == hash &&
      other.size == size &&
      other.modifiedAt == modifiedAt &&
      other.revision == revision &&
      other.globalRevision == globalRevision;

  @override
  int get hashCode =>
      Object.hash(path, hash, size, modifiedAt, revision, globalRevision);
}

/// Backend-independent metadata returned by a fresh stat or post-save stat.
final class EditorRemoteMetadata {
  factory EditorRemoteMetadata({
    String? path,
    String? canonicalPath,
    required EditorRemoteNodeType type,
    String? name,
    String? hash,
    required int? size,
    DateTime? modifiedAt,
    DateTime? mtime,
    String? revision,
    String? rev,
    String? globalRevision,
    String? grev,
  }) {
    final selectedPath = canonicalPath ?? path;
    if (selectedPath == null) {
      throw ArgumentError('A canonical remote path is required.');
    }
    if (path != null && canonicalPath != null && path != canonicalPath) {
      throw ArgumentError('Remote paths do not match.');
    }
    if (size != null && size < 0) {
      throw ArgumentError.value(size, 'size', 'Size must be nonnegative.');
    }
    final selectedModifiedAt = modifiedAt ?? mtime;
    if (modifiedAt != null && mtime != null && modifiedAt != mtime) {
      throw ArgumentError('Remote modification times do not match.');
    }
    final selectedRevision = revision ?? rev;
    final selectedGlobalRevision = globalRevision ?? grev;
    String? normalizedHash;
    if (hash != null) {
      try {
        normalizedHash = normalizeCloudHash(hash);
      } on ArgumentError {
        // A malformed server hash is useful as a conflict observation but is
        // never accepted as proof of a successful save.
        normalizedHash = null;
      }
    }
    return EditorRemoteMetadata._(
      path: normalizeEditorPath(selectedPath),
      type: type,
      name: name,
      hash: normalizedHash,
      size: size,
      modifiedAt: selectedModifiedAt?.toUtc(),
      revision: selectedRevision,
      globalRevision: selectedGlobalRevision,
    );
  }

  const EditorRemoteMetadata._({
    required this.path,
    required this.type,
    required this.name,
    required this.hash,
    required this.size,
    required this.modifiedAt,
    required this.revision,
    required this.globalRevision,
  });

  final String path;
  final EditorRemoteNodeType type;
  final String? name;
  final String? hash;
  final int? size;
  final DateTime? modifiedAt;
  final String? revision;
  final String? globalRevision;

  String get canonicalPath => path;
  DateTime? get mtime => modifiedAt;
  String? get rev => revision;
  String? get grev => globalRevision;
  bool get isFile => type == EditorRemoteNodeType.file;

  @override
  bool operator ==(Object other) =>
      other is EditorRemoteMetadata &&
      other.path == path &&
      other.type == type &&
      other.name == name &&
      other.hash == hash &&
      other.size == size &&
      other.modifiedAt == modifiedAt &&
      other.revision == revision &&
      other.globalRevision == globalRevision;

  @override
  int get hashCode => Object.hash(
    path,
    type,
    name,
    hash,
    size,
    modifiedAt,
    revision,
    globalRevision,
  );
}

/// Result of comparing a captured baseline with one fresh stat.
final class EditorConflictCheckResult {
  const EditorConflictCheckResult._({
    required this.matches,
    required this.current,
    this.failure,
  });

  factory EditorConflictCheckResult.unchanged(EditorRemoteMetadata current) =>
      EditorConflictCheckResult._(matches: true, current: current);

  factory EditorConflictCheckResult.conflict(
    EditorRemoteMetadata? current, {
    EditorSaveFailure? failure,
  }) => EditorConflictCheckResult._(
    matches: false,
    current: current,
    failure: failure,
  );

  final bool matches;
  final EditorRemoteMetadata? current;
  final EditorSaveFailure? failure;

  bool get isConflict => !matches;
  bool get hasConflict => !matches;
  bool get unchanged => matches;
  EditorRemoteMetadata? get currentMetadata => current;
}

/// A typed service failure.  [message] is intentionally safe and never
/// contains a token, dispatcher shard, or remote path.
final class EditorSaveFailure implements Exception {
  const EditorSaveFailure(
    this.type,
    this.message, {
    this.statusCode,
    this.mayHaveSaved = false,
  });

  final EditorSaveFailureType type;
  final String message;
  final int? statusCode;

  /// True when the remote registration may have succeeded even though the
  /// client could not verify it.  Such a failure must not be auto-retried.
  final bool mayHaveSaved;

  bool get isConflict => type == EditorSaveFailureType.conflict;
  bool get isCancelled => type == EditorSaveFailureType.cancelled;
  bool get isPartialSuccess => type == EditorSaveFailureType.partialSuccess;

  bool get isRemoteOutcomeUnknown =>
      type == EditorSaveFailureType.remoteOutcomeUnknown;

  /// A caller may retry ordinary transient failures, but never an operation
  /// whose remote outcome is unknown.
  bool get canRetry => switch (type) {
    EditorSaveFailureType.network ||
    EditorSaveFailureType.timeout ||
    EditorSaveFailureType.service => !mayHaveSaved,
    _ => false,
  };

  @override
  String toString() => message;
}

/// Progress information which contains no credentials or backend URLs.
final class EditorSaveProgress {
  const EditorSaveProgress({
    required this.phase,
    required this.bytes,
    required this.total,
  });

  final EditorSavePhase phase;
  final int bytes;
  final int? total;
}

/// A local ownership failure after the remote node has already been verified.
final class EditorPartialSuccess {
  const EditorPartialSuccess({
    required this.verifiedRemoteNode,
    required this.localFailure,
  });

  final EditorRemoteMetadata verifiedRemoteNode;
  final EditorSaveFailure localFailure;

  EditorRemoteMetadata get remoteNode => verifiedRemoteNode;
}

/// Successful remote save and its local ownership outcome.
final class EditorSaveResult {
  const EditorSaveResult({
    required this.remoteNode,
    required this.choice,
    required this.ownershipPolicy,
    this.partialSuccess,
  });

  final EditorRemoteMetadata remoteNode;
  final EditorSaveChoice choice;
  final EditorOwnershipPolicy ownershipPolicy;
  final EditorPartialSuccess? partialSuccess;

  EditorRemoteMetadata get verifiedRemoteNode => remoteNode;
  EditorRemoteMetadata get metadata => remoteNode;
  String get path => remoteNode.path;
  String get returnedPath => remoteNode.path;
  String? get hash => remoteNode.hash;
  int? get size => remoteNode.size;
  bool get isPartialSuccess => partialSuccess != null;
}

/// Request object for callers that prefer one immutable argument.
final class EditorSaveRequest {
  EditorSaveRequest({
    required this.baseline,
    required Iterable<int> bytes,
    this.choice = EditorSaveChoice.unchanged,
  }) : bytes = List.unmodifiable(bytes);

  final EditorSaveBaseline baseline;
  final List<int> bytes;
  final EditorSaveChoice choice;
}

String normalizeEditorPath(String path) {
  if (path.isEmpty || path.trim() != path) {
    throw ArgumentError.value(
      path,
      'path',
      'Path must not be empty or padded.',
    );
  }
  var normalized = path.startsWith('/') ? path : '/$path';
  if (normalized == '/') return normalized;
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized == '/' ||
      normalized.length > 4096 ||
      normalized.startsWith('//') ||
      normalized.contains('\\') ||
      normalized.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw ArgumentError.value(path, 'path', 'Invalid remote path.');
  }
  final segments = normalized.substring(1).split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw ArgumentError.value(path, 'path', 'Invalid remote path.');
  }
  return '/${segments.join('/')}';
}

String editorParentPath(String path) {
  final normalized = normalizeEditorPath(path);
  final separator = normalized.lastIndexOf('/');
  return separator <= 0 ? '/' : normalized.substring(0, separator);
}
