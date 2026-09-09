import 'package:easy_cloud/core/errors/cloud_failure.dart';
import 'package:easy_cloud/features/browser/application/browser_repository.dart';
import 'package:easy_cloud/features/browser/domain/cloud_folder_page.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:easy_cloud/features/browser/presentation/browser_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads pages using the number of accepted items as offset', () async {
    final repository = _QueueRepository([
      _page(['/a', '/b'], total: 3),
      _page(['/c'], total: 3),
    ]);
    final controller = BrowserController(repository: repository, path: '/');

    await controller.loadInitial();
    await controller.loadMore();

    expect(repository.offsets, [0, 2]);
    expect(controller.items.map((item) => item.path), ['/a', '/b', '/c']);
    expect(controller.hasMore, isFalse);
  });

  test('keeps loaded items when the next page fails', () async {
    final repository = _QueueRepository([
      _page(['/a'], total: 2),
      const CloudFailure(CloudFailureType.network, 'offline'),
    ]);
    final controller = BrowserController(repository: repository, path: '/');

    await controller.loadInitial();
    await controller.loadMore();

    expect(controller.items.single.path, '/a');
    expect(controller.loadMoreFailure?.message, 'offline');
  });

  test('changing sort resets pagination', () async {
    final repository = _QueueRepository([
      _page(['/a'], total: 2),
      _page(['/z'], total: 1),
    ]);
    final controller = BrowserController(repository: repository, path: '/');

    await controller.loadInitial();
    await controller.changeSort(
      const CloudSort(CloudSortField.name, CloudSortOrder.descending),
    );

    expect(repository.offsets, [0, 0]);
    expect(controller.items.single.path, '/z');
  });

  test('overlapping pages advance the server offset', () async {
    final repository = _QueueRepository([
      _page(['/a', '/b'], total: 4),
      _page(['/b', '/c'], total: 4),
    ]);
    final controller = BrowserController(repository: repository, path: '/');

    await controller.loadInitial();
    await controller.loadMore();

    expect(repository.offsets, [0, 2]);
    expect(controller.items.map((item) => item.path), ['/a', '/b', '/c']);
    expect(controller.hasMore, isFalse);
  });
}

CloudFolderPage _page(
  List<String> paths, {
  required int total,
}) => CloudFolderPage(
  folder: const CloudNode(path: '/', name: 'Root', type: CloudNodeType.folder),
  items: [
    for (final path in paths)
      CloudNode(path: path, name: path.substring(1), type: CloudNodeType.file),
  ],
  totalCount: total,
  sort: CloudSort.nameAscending,
);

final class _QueueRepository implements BrowserRepository {
  _QueueRepository(this.results);

  final List<Object> results;
  final offsets = <int>[];

  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) async {
    offsets.add(offset);
    final result = results.removeAt(0);
    if (result is CloudFailure) throw result;
    return result as CloudFolderPage;
  }

  @override
  void close() {}
}
