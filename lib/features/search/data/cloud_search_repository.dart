import '../../../cloud_mail/api/cloud_mail_api.dart';
import '../../browser/domain/cloud_node.dart';
import '../application/search_repository.dart';

final class CloudSearchRepository implements SearchRepository {
  const CloudSearchRepository(this._api);

  final CloudMailApi _api;

  @override
  Future<List<CloudNode>> search(
    String query, {
    String path = '/',
    int limit = 100,
  }) => _api.search(query, path: path, limit: limit);
}
