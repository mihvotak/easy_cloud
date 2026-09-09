import 'dart:async';

import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/auth_failure.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 9, 12);

  test(
    'login saves the returned session without saving the password',
    () async {
      final api = FakeAuthApi(loginResult: session(now, access: 'new-access'));
      final store = MemorySessionStore();
      final repository = AuthRepository(
        api: api,
        store: store,
        clock: () => now,
      );

      final result = await repository.login(
        email: 'test@mail.ru',
        password: 'app-password',
      );

      expect(result.accessToken, 'new-access');
      expect(store.session, same(result));
      expect(api.lastEmail, 'test@mail.ru');
      expect(api.lastPassword, 'app-password');
    },
  );

  test(
    'restore returns a valid stored session without a network call',
    () async {
      final stored = session(now);
      final api = FakeAuthApi();
      final store = MemorySessionStore()..session = stored;
      final repository = AuthRepository(
        api: api,
        store: store,
        clock: () => now,
      );

      expect(await repository.restore(), same(stored));
      expect(api.refreshCalls, 0);
    },
  );

  test('restore refreshes and persists an expiring session', () async {
    final old = session(now, expiresAt: now.add(const Duration(seconds: 30)));
    final rotated = session(now, access: 'rotated', refresh: 'rotated-refresh');
    final api = FakeAuthApi(refreshResult: rotated);
    final store = MemorySessionStore()..session = old;
    final repository = AuthRepository(api: api, store: store, clock: () => now);

    expect(await repository.restore(), same(rotated));
    expect(store.session, same(rotated));
    expect(api.refreshCalls, 1);
  });

  test(
    'network failure preserves an expired session for offline use',
    () async {
      final old = session(
        now,
        expiresAt: now.subtract(const Duration(minutes: 1)),
      );
      final api = FakeAuthApi(
        refreshFailure: const AuthFailure(AuthFailureType.network, 'offline'),
      );
      final store = MemorySessionStore()..session = old;
      final repository = AuthRepository(
        api: api,
        store: store,
        clock: () => now,
      );

      expect(await repository.restore(), same(old));
      expect(store.session, same(old));
    },
  );

  test('invalid refresh clears the session', () async {
    final old = session(
      now,
      expiresAt: now.subtract(const Duration(minutes: 1)),
    );
    final api = FakeAuthApi(
      refreshFailure: const AuthFailure(
        AuthFailureType.authRequired,
        'expired',
      ),
    );
    final store = MemorySessionStore()..session = old;
    final repository = AuthRepository(api: api, store: store, clock: () => now);

    expect(await repository.restore(), isNull);
    expect(store.session, isNull);
  });

  test('logout clears secure session state', () async {
    final store = MemorySessionStore()..session = session(now);
    final repository = AuthRepository(
      api: FakeAuthApi(),
      store: store,
      clock: () => now,
    );

    await repository.logout();

    expect(store.session, isNull);
  });

  test('concurrent refresh calls share one token rotation', () async {
    final old = session(now, expiresAt: now.add(const Duration(seconds: 30)));
    final rotated = session(now, access: 'rotated');
    final api = FakeAuthApi(refreshResult: rotated);
    final repository = AuthRepository(
      api: api,
      store: MemorySessionStore()..session = old,
      clock: () => now,
    );

    final results = await Future.wait([
      repository.refresh(old),
      repository.refresh(old),
      repository.refresh(old),
    ]);

    expect(results, everyElement(same(rotated)));
    expect(api.refreshCalls, 1);
  });

  test('a refresh finishing after logout cannot restore the session', () async {
    final refreshResult = Completer<CloudSession>();
    final api = _DelayedRefreshApi(refreshResult.future);
    final store = MemorySessionStore();
    final repository = AuthRepository(api: api, store: store, clock: () => now);
    final old = await repository.login(
      email: 'test@mail.ru',
      password: 'password',
    );

    final refresh = repository.refresh(old);
    await repository.logout();
    refreshResult.complete(session(now, access: 'late-access'));

    await expectLater(refresh, throwsA(isA<AuthFailure>()));
    expect(repository.currentSession, isNull);
    expect(store.session, isNull);
  });
}

CloudSession session(
  DateTime now, {
  String access = 'access',
  String refresh = 'refresh',
  DateTime? expiresAt,
}) => CloudSession(
  email: 'test@mail.ru',
  accessToken: access,
  refreshToken: refresh,
  csrfToken: 'csrf',
  expiresAt: expiresAt ?? now.add(const Duration(hours: 1)),
);

final class FakeAuthApi implements AuthApi {
  FakeAuthApi({this.loginResult, this.refreshResult, this.refreshFailure});

  final CloudSession? loginResult;
  final CloudSession? refreshResult;
  final AuthFailure? refreshFailure;
  int refreshCalls = 0;
  String? lastEmail;
  String? lastPassword;

  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async {
    lastEmail = email;
    lastPassword = password;
    return loginResult ?? session(DateTime.utc(2026, 9, 9, 12));
  }

  @override
  Future<CloudSession> refresh(CloudSession session) async {
    refreshCalls++;
    if (refreshFailure case final failure?) throw failure;
    return refreshResult ?? session;
  }

  @override
  void close() {}
}

final class _DelayedRefreshApi implements AuthApi {
  _DelayedRefreshApi(this.result);

  final Future<CloudSession> result;

  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => session(DateTime.utc(2026, 9, 9, 12));

  @override
  Future<CloudSession> refresh(CloudSession session) => result;

  @override
  void close() {}
}
