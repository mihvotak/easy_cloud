import '../../../local/cache/content_addressed_file_cache.dart';

/// Durable metadata for a verified object that was prepared for a transient
/// external open.
///
/// The record is account-scoped by [TransientObjectIndex]. It deliberately
/// contains no email or local filesystem path.
final class TransientObjectRecord {
  TransientObjectRecord({
    required String hash,
    required this.size,
    required DateTime lastAccessedAt,
  }) : hash = normalizeCloudHash(hash),
       lastAccessedAt = lastAccessedAt.toUtc() {
    if (size < 0) {
      throw ArgumentError.value(size, 'size', 'Size must be nonnegative.');
    }
  }

  final String hash;
  final int size;
  final DateTime lastAccessedAt;

  @override
  bool operator ==(Object other) =>
      other is TransientObjectRecord &&
      other.hash == hash &&
      other.size == size &&
      other.lastAccessedAt == lastAccessedAt;

  @override
  int get hashCode => Object.hash(hash, size, lastAccessedAt);
}
