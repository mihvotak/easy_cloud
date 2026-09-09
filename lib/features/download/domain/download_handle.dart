import 'dart:io';

import 'download_progress.dart';

abstract interface class DownloadHandle {
  Stream<DownloadProgress> get progress;

  Future<File> get result;

  void cancel();
}
