import 'dart:async';
import 'dart:io';

import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/domain/auth_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bounds a login whose token response never finishes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hold = Completer<void>();
    final serving = server.listen((request) async {
      request.response.write('{"access_token":"access"');
      await hold.future;
    });
    final api = CloudAuthApi(
      oauthUrl: Uri.parse('http://127.0.0.1:${server.port}/token'),
      requestTimeout: const Duration(milliseconds: 100),
      readTimeout: const Duration(milliseconds: 100),
      operationTimeout: const Duration(seconds: 1),
    );

    try {
      await expectLater(
        api.login(email: 'test@mail.ru', password: 'password'),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.type,
            'type',
            AuthFailureType.timeout,
          ),
        ),
      );
    } finally {
      api.close();
      hold.complete();
      await server.close(force: true);
      await serving.cancel();
    }
  });
}
