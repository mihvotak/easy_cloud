import 'download_cancellation.dart';
import 'download_progress.dart';
import 'download_request.dart';

abstract interface class DownloadTransport {
  Future<DownloadResult> download(
    DownloadRequest request, {
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellation,
  });

  void close();
}
