import '../../browser/domain/cloud_folder_page.dart';
import '../../browser/domain/cloud_sort.dart';
import '../domain/cloud_metadata_cache_result.dart';

export '../domain/cloud_metadata_cache_result.dart';

const int cloudFolderPageSize = 100;

/// Persistence-agnostic storage for account-isolated folder metadata
/// snapshots.
abstract interface class CloudMetadataCache {
  /// Adds one page to a folder snapshot generation.
  ///
  /// An offset of zero starts a new staging generation. Later pages must use
  /// the next offset expected by that generation.
  Future<void> storePage(
    String email,
    CloudFolderPage page, {
    int offset = 0,
    int limit = cloudFolderPageSize,
    required DateTime fetchedAt,
  });

  /// Reads a locally sorted page from the published snapshot, or from the
  /// only available staging snapshot when no generation has been published.
  Future<CachedCloudFolderPage?> readFolder(
    String email,
    String path, {
    CloudSort sort = CloudSort.nameAscending,
    int offset = 0,
    int limit = cloudFolderPageSize,
  });

  Future<void> close();
}
