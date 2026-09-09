import '../../../local/cache/content_addressed_file_cache.dart';

/// A validated description of a file available in the offline cache.
///
/// The record deliberately contains no local object path. That path is
/// derived from [hash] by the content-addressed cache.
final class OfflineFileRecord {
  OfflineFileRecord({
    required String path,
    required this.name,
    required String hash,
    required this.size,
    DateTime? modifiedAt,
    this.revision,
    this.globalRevision,
    required DateTime cachedAt,
  }) : path = normalizeOfflineRemotePath(path),
       hash = normalizeCloudHash(hash),
       modifiedAt = modifiedAt?.toUtc(),
       cachedAt = cachedAt.toUtc() {
    if (size < 0) {
      throw ArgumentError.value(size, 'size', 'Size must be nonnegative.');
    }
    if (this.path == '/') {
      throw ArgumentError.value(path, 'path', 'A file path is required.');
    }
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Name must not be empty.');
    }
  }

  final String path;
  final String name;
  final String hash;
  final int size;
  final DateTime? modifiedAt;
  final String? revision;
  final String? globalRevision;
  final DateTime cachedAt;

  @override
  bool operator ==(Object other) =>
      other is OfflineFileRecord &&
      other.path == path &&
      other.name == name &&
      other.hash == hash &&
      other.size == size &&
      other.modifiedAt == modifiedAt &&
      other.revision == revision &&
      other.globalRevision == globalRevision &&
      other.cachedAt == cachedAt;

  @override
  int get hashCode => Object.hash(
    path,
    name,
    hash,
    size,
    modifiedAt,
    revision,
    globalRevision,
    cachedAt,
  );
}

/// Returns the canonical remote path used as the index key.
///
/// Paths may be supplied without a leading slash and may have trailing
/// slashes. Root is the only path represented by a slash after normalization.
String normalizeOfflineRemotePath(String path) {
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
  if (normalized == '/') {
    throw ArgumentError.value(path, 'path', 'Invalid remote path.');
  }

  final segments = normalized.substring(1).split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw ArgumentError.value(path, 'path', 'Invalid remote path.');
  }
  return normalized;
}
