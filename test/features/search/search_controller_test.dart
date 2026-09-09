import 'dart:async';

import 'package:easy_cloud/core/errors/cloud_failure.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/search/application/search_repository.dart';
import 'package:easy_cloud/features/search/presentation/search_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'does not call repository for queries shorter than two characters',
    () async {
      final repository = _SearchRepository();
      final controller = SearchController(repository: repository);

      await controller.search(' a ');

      expect(repository.queries, isEmpty);
      expect(controller.isQueryTooShort, isTrue);
      expect(controller.isLoading, isFalse);
      expect(controller.results, isEmpty);
    },
  );

  test('ignores a stale response from an older search', () async {
    final first = Completer<List<CloudNode>>();
    final second = Completer<List<CloudNode>>();
    final repository = _SearchRepository(responses: [first, second]);
    final controller = SearchController(repository: repository, path: '/docs');

    final firstSearch = controller.search('first');
    final secondSearch = controller.search('second');
    second.complete([_node('/second')]);
    await secondSearch;
    first.complete([_node('/first')]);
    await firstSearch;

    expect(repository.paths, ['/docs', '/docs']);
    expect(controller.query, 'second');
    expect(controller.results.single.path, '/second');
  });

  test('exposes CloudFailure and clears loading', () async {
    final repository = _SearchRepository(
      error: const CloudFailure(CloudFailureType.network, 'offline'),
    );
    final controller = SearchController(repository: repository);

    await controller.search('report');

    expect(controller.error?.message, 'offline');
    expect(controller.isLoading, isFalse);
    expect(controller.results, isEmpty);
  });

  test('completion after dispose does not notify or update state', () async {
    final response = Completer<List<CloudNode>>();
    final controller = SearchController(
      repository: _SearchRepository(responses: [response]),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    final search = controller.search('photo');
    expect(notifications, 1);
    controller.dispose();
    response.complete([_node('/photo.jpg')]);
    await search;

    expect(notifications, 1);
    expect(controller.results, isEmpty);
  });
}

CloudNode _node(String path) => CloudNode(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.file,
);

final class _SearchRepository implements SearchRepository {
  _SearchRepository({this.responses = const [], this.error});

  final List<Completer<List<CloudNode>>> responses;
  final Object? error;
  final queries = <String>[];
  final paths = <String>[];

  @override
  Future<List<CloudNode>> search(
    String query, {
    String path = '/',
    int limit = 100,
  }) {
    queries.add(query);
    paths.add(path);
    if (error case final failure?) return Future.error(failure);
    return responses.removeAt(0).future;
  }
}
