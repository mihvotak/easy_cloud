import '../../browser/domain/cloud_folder_page.dart';

/// A folder page read from the local metadata snapshot cache.
///
/// [page] can represent only the children received so far when [complete] is
/// false. The page's total count remains the count advertised by the server
/// for the snapshot generation.
final class CachedCloudFolderPage {
  const CachedCloudFolderPage({
    required this.page,
    required this.complete,
    required this.fetchedAt,
  });

  final CloudFolderPage page;
  final bool complete;
  final DateTime fetchedAt;
}
