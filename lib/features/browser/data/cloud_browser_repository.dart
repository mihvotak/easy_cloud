import '../../../cloud_mail/api/cloud_mail_api.dart';
import '../application/browser_repository.dart';
import '../domain/cloud_folder_page.dart';
import '../domain/cloud_sort.dart';

final class CloudBrowserRepository implements BrowserRepository {
  const CloudBrowserRepository(this._api);

  final CloudMailApi _api;

  @override
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  }) => _api.listFolder(path, offset: offset, limit: limit, sort: sort);

  @override
  void close() => _api.close();
}
