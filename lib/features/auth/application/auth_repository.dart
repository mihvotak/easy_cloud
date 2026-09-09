import 'dart:async';

import '../data/cloud_auth_api.dart';
import '../data/session_store.dart';
import '../domain/auth_failure.dart';
import '../domain/cloud_session.dart';

final class AuthRepository {
  AuthRepository({
    required AuthApi api,
    required SessionStore store,
    DateTime Function()? clock,
  }) : _api = api,
       _store = store,
       _clock = clock ?? DateTime.now;

  final AuthApi _api;
  final SessionStore _store;
  final DateTime Function() _clock;
  Future<CloudSession>? _refreshing;
  Future<void> _sessionMutation = Future.value();
  CloudSession? _currentSession;
  int _sessionEpoch = 0;
  final _sessionChanges = StreamController<CloudSession?>.broadcast();

  CloudSession? get currentSession => _currentSession;

  Stream<CloudSession?> get sessionChanges => _sessionChanges.stream;

  Future<CloudSession?> restore() async {
    final session = await _store.read();
    if (session == null || !session.needsRefresh(_clock())) {
      _setSession(session);
      return session;
    }

    try {
      return await refresh(session);
    } on AuthFailure catch (failure) {
      if (failure.type == AuthFailureType.authRequired) {
        await _store.clear();
        return null;
      }
      if (failure.type == AuthFailureType.network) {
        _setSession(session);
        return session;
      }
      rethrow;
    }
  }

  Future<CloudSession> login({
    required String email,
    required String password,
  }) async {
    final epoch = ++_sessionEpoch;
    final session = await _api.login(email: email, password: password);
    return _mutateSession(() async {
      if (epoch != _sessionEpoch) {
        throw const AuthFailure(
          AuthFailureType.authRequired,
          'Вход был отменён.',
        );
      }
      await _store.write(session);
      _setSession(session);
      return session;
    });
  }

  Future<CloudSession> requireFreshSession() async {
    final session = _currentSession;
    if (session == null) {
      throw const AuthFailure(
        AuthFailureType.authRequired,
        'Требуется вход в Mail.ru.',
      );
    }
    return session.needsRefresh(_clock()) ? refresh(session) : session;
  }

  Future<CloudSession> refreshAfterRejection(String failedAccessToken) async {
    final session = _currentSession;
    if (session == null) {
      throw const AuthFailure(
        AuthFailureType.authRequired,
        'Сессия истекла. Войдите снова.',
      );
    }
    if (session.accessToken != failedAccessToken) return session;
    return refresh(session);
  }

  Future<CloudSession> refresh(CloudSession session) async {
    final activeRefresh = _refreshing;
    if (activeRefresh != null) return activeRefresh;

    final refresh = _performRefresh(session, _sessionEpoch);
    _refreshing = refresh;
    try {
      return await refresh;
    } finally {
      if (identical(_refreshing, refresh)) _refreshing = null;
    }
  }

  Future<CloudSession> _performRefresh(CloudSession session, int epoch) async {
    try {
      final refreshed = await _api.refresh(session);
      return _mutateSession(() async {
        final current = _currentSession;
        if (epoch != _sessionEpoch ||
            (current != null && current.accessToken != session.accessToken)) {
          if (current != null) return current;
          throw const AuthFailure(
            AuthFailureType.authRequired,
            'Сессия завершена.',
          );
        }
        await _store.write(refreshed);
        _setSession(refreshed);
        return refreshed;
      });
    } on AuthFailure catch (failure) {
      if (failure.type == AuthFailureType.authRequired &&
          epoch == _sessionEpoch) {
        await logout();
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    ++_sessionEpoch;
    _setSession(null);
    await _mutateSession(_store.clear);
  }

  Future<T> _mutateSession<T>(Future<T> Function() operation) {
    final result = _sessionMutation.then((_) => operation());
    _sessionMutation = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  void _setSession(CloudSession? session) {
    _currentSession = session;
    if (!_sessionChanges.isClosed) _sessionChanges.add(session);
  }

  void close() {
    _sessionChanges.close();
    _api.close();
  }
}
