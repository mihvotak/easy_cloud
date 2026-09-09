import '../../browser/domain/cloud_node.dart';

abstract interface class SearchRepository {
  Future<List<CloudNode>> search(
    String query, {
    String path = '/',
    int limit = 100,
  });
}
