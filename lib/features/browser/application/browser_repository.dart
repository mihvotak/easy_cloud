import '../domain/cloud_folder_page.dart';
import '../domain/cloud_sort.dart';

abstract interface class BrowserRepository {
  Future<CloudFolderPage> listFolder(
    String path, {
    int offset = 0,
    int limit = 100,
    CloudSort sort = CloudSort.nameAscending,
  });

  void close();
}
