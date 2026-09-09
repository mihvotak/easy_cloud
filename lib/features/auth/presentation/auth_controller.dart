import 'package:flutter/foundation.dart';

import '../application/auth_repository.dart';
import '../domain/auth_failure.dart';
import '../domain/cloud_session.dart';

enum AuthStatus { loading, signedOut, signedIn }

final class AuthController extends ChangeNotifier {
  AuthController(this._repository);

  final AuthRepository _repository;

  AuthStatus status = AuthStatus.loading;
  CloudSession? session;
  String? errorMessage;
  bool isSubmitting = false;

  Future<void> initialize() async {
    status = AuthStatus.loading;
    notifyListeners();
    try {
      session = await _repository.restore();
      status = session == null ? AuthStatus.signedOut : AuthStatus.signedIn;
    } on AuthFailure catch (failure) {
      status = AuthStatus.signedOut;
      errorMessage = failure.message;
    }
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    if (isSubmitting) return;
    isSubmitting = true;
    errorMessage = null;
    notifyListeners();
    try {
      session = await _repository.login(email: email, password: password);
      status = AuthStatus.signedIn;
    } on AuthFailure catch (failure) {
      errorMessage = failure.message;
    } finally {
      isSubmitting = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final current = session;
    if (current == null || isSubmitting) return;
    isSubmitting = true;
    errorMessage = null;
    notifyListeners();
    try {
      session = await _repository.refresh(current);
    } on AuthFailure catch (failure) {
      errorMessage = failure.message;
      if (failure.type == AuthFailureType.authRequired) {
        await _repository.logout();
        session = null;
        status = AuthStatus.signedOut;
      }
    } finally {
      isSubmitting = false;
      notifyListeners();
    }
  }

  Future<void> refreshIfNeeded() async {
    final current = session;
    if (current == null || !current.needsRefresh(DateTime.now())) return;
    await refresh();
  }

  Future<void> logout() async {
    if (isSubmitting) return;
    isSubmitting = true;
    errorMessage = null;
    notifyListeners();
    try {
      await _repository.logout();
      session = null;
      status = AuthStatus.signedOut;
    } on AuthFailure catch (failure) {
      errorMessage = failure.message;
    } finally {
      isSubmitting = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _repository.close();
    super.dispose();
  }
}
