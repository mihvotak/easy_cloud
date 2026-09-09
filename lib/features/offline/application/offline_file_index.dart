import '../domain/offline_file_record.dart';

export '../domain/offline_file_record.dart';

/// Persistence-agnostic storage for metadata of offline files.
abstract interface class OfflineFileIndex {
  Future<void> upsert(String email, OfflineFileRecord record);

  Future<List<OfflineFileRecord>> list(String email);

  Future<void> remove(String email, String path);

  Future<void> clearAccount(String email);

  Future<void> close();
}
