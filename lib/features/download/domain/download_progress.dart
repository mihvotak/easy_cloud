enum DownloadPhase { resolving, receiving, verifying, committed }

final class DownloadProgress {
  const DownloadProgress({
    required this.bytes,
    required this.total,
    required this.resumed,
    this.phase = DownloadPhase.receiving,
    this.cacheHit = false,
  });

  final int bytes;
  final int? total;
  final bool resumed;
  final DownloadPhase phase;
  final bool cacheHit;
}

typedef DownloadProgressCallback = void Function(DownloadProgress progress);
