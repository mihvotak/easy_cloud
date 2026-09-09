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

  Future<CloudSession?> restore() async {
    final session = await _store.read();
    if (session == null || !session.needsRefresh(_clock())) return session;

    try {
      return await refresh(session);
    } on AuthFailure catch (failure) {
      if (failure.type == AuthFailureType.authRequired) {
        await _store.clear();
        return null;
      }
      if (failure.type == AuthFailureType.network) return session;
      rethrow;
    }
  }

  Future<CloudSession> login({
    required String email,
    required String password,
  }) async {
    final session = await _api.login(email: email, password: password);
    await _store.write(session);
    return session;
  }

  Future<CloudSession> refresh(CloudSession session) async {
    final activeRefresh = _refreshing;
    if (activeRefresh != null) return activeRefresh;

    final refresh = _performRefresh(session);
    _refreshing = refresh;
    try {
      return await refresh;
    } finally {
      if (identical(_refreshing, refresh)) _refreshing = null;
    }
  }

  Future<CloudSession> _performRefresh(CloudSession session) async {
    try {
      final refreshed = await _api.refresh(session);
      await _store.write(refreshed);
      return refreshed;
    } on AuthFailure catch (failure) {
      if (failure.type == AuthFailureType.authRequired) await _store.clear();
      rethrow;
    }
  }

  Future<void> logout() => _store.clear();

  void close() => _api.close();
}
