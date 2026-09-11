import '../domain/offline_file_record.dart';
import 'offline_target_index.dart';

export 'cloud_metadata_cache.dart';
export 'offline_target_index.dart';
export 'transient_object_index.dart';
export '../domain/offline_file_record.dart';
export '../domain/offline_target.dart';
export '../domain/offline_target_queue.dart';
export '../domain/transient_object_record.dart';

/// Persistence-agnostic storage for metadata of offline files.
abstract interface class OfflineFileIndex {
  Future<void> upsert(String email, OfflineFileRecord record);

  Future<List<OfflineFileRecord>> list(String email);

  /// Returns the stored records for the requested remote paths, keyed by
  /// canonical path.
  ///
  /// Implementations must keep the lookup scoped to [email]. Missing paths
  /// are omitted from the returned map.
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  );

  /// Returns whether a durable offline reference in the same account protects
  /// [hash]. Direct rows always count; target memberships count only when
  /// their readiness is ready and their hash is valid. Transient references
  /// are intentionally queried through [TransientObjectIndex] instead.
  ///
  /// Implementations must normalize [hash] and scope the query to [email].
  Future<bool> hasHashReference(String email, String hash);

  Future<void> remove(String email, String path);

  Future<void> clearAccount(String email);

  Future<void> close();
}

/// Durable storage required by target-aware download operations.
///
/// Keeping this as a nominal capability prevents a download repository from
/// silently constructing with a direct-file-only index and failing only when a
/// target operation is first attempted.
abstract interface class OfflineTargetStorage
    implements OfflineFileIndex, OfflineTargetIndex {}
