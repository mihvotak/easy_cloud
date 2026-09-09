enum CloudFailureType {
  authRequired,
  network,
  timeout,
  service,
  notFound,
  permissionDenied,
  invalidResponse,
}

final class CloudFailure implements Exception {
  const CloudFailure(this.type, this.message, {this.statusCode});

  final CloudFailureType type;
  final String message;
  final int? statusCode;

  bool get canRetry => switch (type) {
    CloudFailureType.network ||
    CloudFailureType.timeout ||
    CloudFailureType.service => true,
    _ => false,
  };

  @override
  String toString() => message;
}
