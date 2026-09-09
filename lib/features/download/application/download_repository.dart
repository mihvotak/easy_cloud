import '../../browser/domain/cloud_node.dart';
import '../domain/download_handle.dart';

abstract interface class DownloadRepository {
  DownloadHandle start(CloudNode node);

  void close();
}
