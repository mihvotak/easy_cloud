enum AuthFailureType {
  invalidCredentials,
  authRequired,
  network,
  service,
  invalidResponse,
  secureStorage,
}

final class AuthFailure implements Exception {
  const AuthFailure(this.type, this.message);

  final AuthFailureType type;
  final String message;

  @override
  String toString() => message;
}
