import 'package:easy_cloud/core/errors/cloud_failure.dart';
import 'package:easy_cloud/features/browser/application/browser_repository.dart';
import 'package:easy_cloud/features/browser/domain/cloud_folder_page.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:easy_cloud/features/browser/presentation/browser_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exposes cached content and its connection failure', () async {
    final failure = const CloudFailure(CloudFailureType.network, 'offline');
    final cachedAt = DateTime.utc(2026, 9, 10, 12);
    final repository = _QueueRepository([
      _page(
        ['/cached'],
        total: 1,
        source: CloudFolderPageSource.cache,
        connectionFailure: failure,
        cachedAt: cachedAt,
      ),
    ]);
    final controller = BrowserController(repository: repository, path: '/');

    await controller.loadInitial();

    expect(controller.folder?.name, 'Root');
    expect(controller.items.single.path, '/cached');
    expect(controller.source, CloudFolderPageSource.cache);
    expect(controller.cachedAt, cachedAt);
    expect(controller.snapshotComplete, isTrue);
    expect(controller.connectionFailure, same(failure));
    expect(controller.initialFailure, isNull);
  });

  test(
    'refresh fallback replaces content without entering initial failure',
    () async {
      final failure = const CloudFailure(CloudFailureType.network, 'offline');
      final repository = _QueueRepository([
        _page(['/before'], total: 1),
        _page(
          ['/cached'],
          total: 1,
          source: CloudFolderPageSource.cache,
          connectionFailure: failure,
        ),
      ]);
      final controller = BrowserController(repository: repository, path: '/');

      await controller.loadInitial();
      await controller.refresh();

      expect(controller.items.single.path, '/cached');
      expect(controller.initialFailure, isNull);
      expect(controller.connectionFailure, same(failure));
    },
  );

  test(
    'retryConnection refreshes cached content and clears the panel state',
    () async {
      final failure = const CloudFailure(CloudFailureType.network, 'offline');
      final repository = _QueueRepository([
        _page(
          ['/cached'],
          total: 1,
          source: CloudFolderPageSource.cache,
          connectionFailure: failure,
        ),
        _page(['/remote'], total: 1),
      ]);
      final controller = BrowserController(repository: repository, path: '/');

      await controller.loadInitial();
      await controller.retryConnection();

      expect(repository.offsets, [0, 0]);
      expect(controller.items.single.path, '/remote');
      expect(controller.source, CloudFolderPageSource.remote);
      expect(controller.connectionFailure, isNull);
      expect(controller.cachedAt, isNull);
    },
  );

  test('incomplete cached pagination cannot be retried indefinitely', () async {
    final failure = const CloudFailure(CloudFailureType.network, 'offline');
    final repository = _QueueRepository([
      _page(['/a'], total: 2),
      _page(
        ['/b'],
        total: 2,
        source: CloudFolderPageSource.cache,
        connectionFailure: failure,
        snapshotComplete: false,
      ),
    ]);
    final controller = BrowserController(repository: repository, path: '/');

    await controller.loadInitial();
    await controller.loadMore();
    await controller.loadMore();

    expect(controller.items.map((item) => item.path), ['/a', '/b']);
    expect(controller.snapshotComplete, isFalse);
    expect(controller.connectionFailure, same(failure));
    expect(controller.hasMore, isFalse);
    expect(repository.offsets, [0, 1]);
  });

  test(
    'keeps the full-screen error when the initial request has no cache',
    () async {
      final failure = const CloudFailure(CloudFailureType.network, 'offline');
      final repository = _QueueRepository([failure]);
      final controller = BrowserController(repository: repository, path: '/');

      await controller.loadInitial();

      expect(controller.items, isEmpty);
      expect(controller.folder, isNull);
      expect(controller.initialFailure, same(failure));
      expect(controller.connectionFailure, isNull);
      expect(controller.source, CloudFolderPageSource.remote);
    },
  );

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
  CloudFolderPageSource source = CloudFolderPageSource.remote,
  CloudFailure? connectionFailure,
  DateTime? cachedAt,
  bool snapshotComplete = true,
}) => CloudFolderPage(
  folder: const CloudNode(path: '/', name: 'Root', type: CloudNodeType.folder),
  items: [
    for (final path in paths)
      CloudNode(path: path, name: path.substring(1), type: CloudNodeType.file),
  ],
  totalCount: total,
  sort: CloudSort.nameAscending,
  source: source,
  connectionFailure: connectionFailure,
  cachedAt: cachedAt,
  snapshotComplete: snapshotComplete,
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
