import 'dart:io';

import '../../browser/domain/cloud_node.dart';
import 'download_progress.dart';

abstract interface class DownloadHandle {
  Stream<DownloadProgress> get progress;

  Future<File> get result;

  void cancel();
}

/// Optional metadata published by a verified open operation. Existing handle
/// implementations do not need to implement this interface; callers fall
/// back to the node they requested when the richer result is unavailable.
abstract interface class VerifiedDownloadHandle implements DownloadHandle {
  CloudNode? get verifiedNode;

  set verifiedNode(CloudNode? value);
}
