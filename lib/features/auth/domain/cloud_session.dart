final class CloudSession {
  const CloudSession({
    required this.email,
    required this.accessToken,
    required this.refreshToken,
    required this.csrfToken,
    required this.expiresAt,
  });

  factory CloudSession.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported session version.');
    }
    final expiresAt = DateTime.tryParse(json['expiresAt'] as String? ?? '');
    if (expiresAt == null) {
      throw const FormatException('Invalid session expiration.');
    }
    return CloudSession(
      email: _requiredString(json, 'email'),
      accessToken: _requiredString(json, 'accessToken'),
      refreshToken: _requiredString(json, 'refreshToken'),
      csrfToken: _requiredString(json, 'csrfToken'),
      expiresAt: expiresAt.toUtc(),
    );
  }

  final String email;
  final String accessToken;
  final String refreshToken;
  final String csrfToken;
  final DateTime expiresAt;

  bool needsRefresh(DateTime now) =>
      !expiresAt.isAfter(now.toUtc().add(const Duration(minutes: 1)));

  Map<String, Object?> toJson() => {
    'version': 1,
    'email': email,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'csrfToken': csrfToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'authType': 'appPassword',
  };
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Missing session field: $key');
  }
  return value;
}
