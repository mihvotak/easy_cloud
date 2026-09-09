import 'dart:io';

/// A binary download target. [partFile] is the temporary target supplied by
/// the caller, never a final cache object.
final class DownloadRequest {
  DownloadRequest({
    required this.remotePath,
    required this.partFile,
    this.expectedSize,
  }) {
    if (expectedSize != null && expectedSize! < 0) {
      throw ArgumentError.value(expectedSize, 'expectedSize');
    }
  }

  final String remotePath;
  final File partFile;
  final int? expectedSize;
}

final class DownloadResult {
  const DownloadResult({
    required this.partFile,
    required this.bytes,
    required this.total,
    required this.resumed,
  });

  final File partFile;
  final int bytes;
  final int? total;
  final bool resumed;
}
