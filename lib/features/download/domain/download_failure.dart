enum DownloadFailureType {
  authRequired,
  network,
  timeout,
  service,
  notFound,
  permissionDenied,
  invalidResponse,
  disk,
  cancelled,
  integrity,
}

class DownloadFailure implements Exception {
  const DownloadFailure(this.type, this.message, {this.statusCode, this.cause});

  final DownloadFailureType type;
  final String message;
  final int? statusCode;
  final Object? cause;

  bool get isCancelled => type == DownloadFailureType.cancelled;

  bool get canRetry => switch (type) {
    DownloadFailureType.network ||
    DownloadFailureType.timeout ||
    DownloadFailureType.service => true,
    _ => false,
  };

  @override
  String toString() => message;
}

final class DownloadCancelled extends DownloadFailure {
  const DownloadCancelled([String message = 'Загрузка отменена.'])
    : super(DownloadFailureType.cancelled, message);
}

final class DownloadIntegrityFailure extends DownloadFailure {
  const DownloadIntegrityFailure(
    String message, {
    this.expectedHash,
    this.actualHash,
    this.expectedSize,
    this.actualSize,
    Object? cause,
  }) : super(DownloadFailureType.integrity, message, cause: cause);

  final String? expectedHash;
  final String? actualHash;
  final int? expectedSize;
  final int? actualSize;
}
