import '../../../core/errors/cloud_failure.dart';
import 'cloud_node.dart';
import 'cloud_sort.dart';

enum CloudFolderPageSource { remote, cache }

final class CloudFolderPage {
  const CloudFolderPage({
    required this.folder,
    required this.items,
    required this.totalCount,
    required this.sort,
    this.source = CloudFolderPageSource.remote,
    this.connectionFailure,
    this.cachedAt,
    this.snapshotComplete = true,
  });

  final CloudNode folder;
  final List<CloudNode> items;
  final int totalCount;
  final CloudSort sort;
  final CloudFolderPageSource source;
  final CloudFailure? connectionFailure;
  final DateTime? cachedAt;
  final bool snapshotComplete;
}
