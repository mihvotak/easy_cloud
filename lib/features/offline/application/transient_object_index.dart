import '../domain/transient_object_record.dart';

/// Durable account-scoped references for objects prepared for external open.
///
/// Implementations must accept an account email only as an input identity and
/// must persist an account key rather than the raw email. All methods are
/// intentionally focused so callers cannot access account-key internals.
abstract interface class TransientObjectIndex {
  /// Inserts or updates the transient reference and its LRU timestamp.
  Future<void> touchTransient(String email, TransientObjectRecord record);

  /// Returns oldest references first. Ties must be deterministic by hash.
  Future<List<TransientObjectRecord>> listTransient(String email);

  Future<void> removeTransient(String email, String hash);

  Future<bool> hasTransientReference(String email, String hash);
}
