import 'cloud_node.dart';
import 'cloud_sort.dart';

final class CloudFolderPage {
  const CloudFolderPage({
    required this.folder,
    required this.items,
    required this.totalCount,
    required this.sort,
  });

  final CloudNode folder;
  final List<CloudNode> items;
  final int totalCount;
  final CloudSort sort;
}
