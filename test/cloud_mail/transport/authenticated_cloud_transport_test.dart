import 'dart:io';

import 'package:easy_cloud/cloud_mail/transport/authenticated_cloud_transport.dart';
import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'refreshes once after rejection and retries with rotated tokens',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seenAccessTokens = <String>[];
      final seenCsrfTokens = <String?>[];
      final seenCsrfQueryTokens = <String?>[];
      final serving = server.listen((request) async {
        seenAccessTokens.add(request.uri.queryParameters['access_token']!);
        seenCsrfTokens.add(request.headers.value('X-CSRF-Token'));
        seenCsrfQueryTokens.add(request.uri.queryParameters['token']);
        request.response.statusCode = seenAccessTokens.length == 1 ? 403 : 200;
        request.response.write('{"status":200,"body":{}}');
        await request.response.close();
      });
      final api = _RotatingAuthApi();
      final auth = AuthRepository(api: api, store: MemorySessionStore());
      await auth.login(email: 'test@mail.ru', password: 'password');
      final transport = AuthenticatedCloudTransport(
        authRepository: auth,
        apiUrl: Uri.parse('http://127.0.0.1:${server.port}/api/'),
      );

      try {
        final response = await transport.get(
          'folder/find',
          includeCsrfQuery: true,
        );

        expect(response.statusCode, 200);
        expect(api.refreshCalls, 1);
        expect(seenAccessTokens, ['old-access', 'new-access']);
        expect(seenCsrfTokens, ['old-csrf', 'new-csrf']);
        expect(seenCsrfQueryTokens, ['old-csrf', 'new-csrf']);
      } finally {
        transport.close();
        auth.close();
        await server.close(force: true);
        await serving.cancel();
      }
    },
  );
}

final class _RotatingAuthApi implements AuthApi {
  int refreshCalls = 0;

  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => CloudSession(
    email: email,
    accessToken: 'old-access',
    refreshToken: 'old-refresh',
    csrfToken: 'old-csrf',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );

  @override
  Future<CloudSession> refresh(CloudSession session) async {
    refreshCalls++;
    return CloudSession(
      email: session.email,
      accessToken: 'new-access',
      refreshToken: 'new-refresh',
      csrfToken: 'new-csrf',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  void close() {}
}
