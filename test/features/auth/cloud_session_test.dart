import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes and restores a versioned session', () {
    final original = CloudSession(
      email: 'test@mail.ru',
      accessToken: 'access',
      refreshToken: 'refresh',
      csrfToken: 'csrf',
      expiresAt: DateTime.utc(2026, 9, 9, 13),
    );

    final restored = CloudSession.fromJson(original.toJson());

    expect(restored.email, original.email);
    expect(restored.accessToken, original.accessToken);
    expect(restored.refreshToken, original.refreshToken);
    expect(restored.csrfToken, original.csrfToken);
    expect(restored.expiresAt, original.expiresAt);
  });

  test('refreshes one minute before expiration', () {
    final now = DateTime.utc(2026, 9, 9, 12);
    final session = CloudSession(
      email: 'test@mail.ru',
      accessToken: 'access',
      refreshToken: 'refresh',
      csrfToken: 'csrf',
      expiresAt: now.add(const Duration(seconds: 59)),
    );

    expect(session.needsRefresh(now), isTrue);
  });

  test('rejects unknown persisted session versions', () {
    expect(
      () => CloudSession.fromJson({
        'version': 2,
        'expiresAt': DateTime.now().toIso8601String(),
      }),
      throwsFormatException,
    );
  });
}
