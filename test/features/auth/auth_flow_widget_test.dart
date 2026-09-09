import 'package:easy_cloud/app/easy_cloud_app.dart';
import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows login and connects an account', (tester) async {
    final repository = AuthRepository(
      api: _WidgetAuthApi(),
      store: MemorySessionStore(),
    );
    await tester.pumpWidget(EasyCloudApp(authRepository: repository));
    await tester.pumpAndSettle();

    expect(find.text('Ваше облако.\nБез лишнего.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email Mail.ru'),
      'test@mail.ru',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Пароль приложения'),
      'app-password',
    );
    await tester.tap(find.text('Подключить облако'));
    await tester.pumpAndSettle();

    expect(find.text('Облако подключено'), findsOneWidget);
    expect(find.text('test@mail.ru'), findsOneWidget);
  });

  testWidgets('restores an existing session without showing login', (
    tester,
  ) async {
    final store = MemorySessionStore()
      ..session = _session(DateTime.now().add(const Duration(hours: 1)));
    await tester.pumpWidget(
      EasyCloudApp(
        authRepository: AuthRepository(api: _WidgetAuthApi(), store: store),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Облако подключено'), findsOneWidget);
    expect(find.text('Подключить облако'), findsNothing);
  });
}

CloudSession _session(DateTime expiresAt) => CloudSession(
  email: 'test@mail.ru',
  accessToken: 'access',
  refreshToken: 'refresh',
  csrfToken: 'csrf',
  expiresAt: expiresAt,
);

final class _WidgetAuthApi implements AuthApi {
  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => _session(DateTime.now().add(const Duration(hours: 1)));

  @override
  Future<CloudSession> refresh(CloudSession session) async => session;

  @override
  void close() {}
}
