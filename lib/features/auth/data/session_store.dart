import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/auth_failure.dart';
import '../domain/cloud_session.dart';

abstract interface class SessionStore {
  Future<CloudSession?> read();

  Future<void> write(CloudSession session);

  Future<void> clear();
}

final class SecureSessionStore implements SessionStore {
  SecureSessionStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(migrateWithBackup: true),
          );

  static const _sessionKey = 'cloud_mail_session_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<CloudSession?> read() async {
    try {
      final encoded = await _storage.read(key: _sessionKey);
      if (encoded == null) return null;
      final json = jsonDecode(encoded);
      if (json is! Map) throw const FormatException('Invalid session JSON.');
      return CloudSession.fromJson(json.cast<String, Object?>());
    } on FormatException {
      await clear();
      return null;
    } catch (_) {
      throw const AuthFailure(
        AuthFailureType.secureStorage,
        'Не удалось прочитать защищённую сессию.',
      );
    }
  }

  @override
  Future<void> write(CloudSession session) async {
    try {
      await _storage.write(
        key: _sessionKey,
        value: jsonEncode(session.toJson()),
      );
    } catch (_) {
      throw const AuthFailure(
        AuthFailureType.secureStorage,
        'Не удалось сохранить защищённую сессию.',
      );
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _sessionKey);
    } catch (_) {
      throw const AuthFailure(
        AuthFailureType.secureStorage,
        'Не удалось удалить защищённую сессию.',
      );
    }
  }
}

final class MemorySessionStore implements SessionStore {
  CloudSession? session;

  @override
  Future<void> clear() async => session = null;

  @override
  Future<CloudSession?> read() async => session;

  @override
  Future<void> write(CloudSession value) async => session = value;
}
