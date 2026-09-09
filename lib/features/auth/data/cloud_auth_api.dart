import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/auth_failure.dart';
import '../domain/cloud_session.dart';

abstract interface class AuthApi {
  Future<CloudSession> login({required String email, required String password});

  Future<CloudSession> refresh(CloudSession session);

  void close();
}

final class CloudAuthApi implements AuthApi {
  CloudAuthApi({
    HttpClient? httpClient,
    this.clientId = 'cloud-win',
    Uri? oauthUrl,
    Uri? apiUrl,
    DateTime Function()? clock,
  }) : _httpClient = httpClient ?? HttpClient(),
       oauthUrl = oauthUrl ?? Uri.parse('https://o2.mail.ru/token'),
       apiUrl = apiUrl ?? Uri.parse('https://cloud.mail.ru/api/v2/'),
       _clock = clock ?? DateTime.now;

  final HttpClient _httpClient;
  final String clientId;
  final Uri oauthUrl;
  final Uri apiUrl;
  final DateTime Function() _clock;

  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async {
    final tokens = await _requestTokens({
      'client_id': clientId,
      'grant_type': 'password',
      'username': email.trim(),
      'password': password,
    }, invalidCredentials: true);
    return _createSession(email.trim(), tokens);
  }

  @override
  Future<CloudSession> refresh(CloudSession session) async {
    final tokens = await _requestTokens({
      'client_id': clientId,
      'grant_type': 'refresh_token',
      'refresh_token': session.refreshToken,
    });
    return _createSession(session.email, tokens);
  }

  Future<CloudSession> _createSession(String email, _OAuthTokens tokens) async {
    final csrf = await _requestCsrf(tokens.accessToken);
    return CloudSession(
      email: email,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      csrfToken: csrf,
      expiresAt: _clock().toUtc().add(Duration(seconds: tokens.expiresIn)),
    );
  }

  Future<_OAuthTokens> _requestTokens(
    Map<String, String> form, {
    bool invalidCredentials = false,
  }) async {
    final response = await _sendForm(oauthUrl, form);
    final body = _decodeObject(response.bytes);
    final accessToken = body['access_token'];
    final refreshToken = body['refresh_token'];
    final expiresIn = _asInt(body['expires_in']);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        accessToken is! String ||
        accessToken.isEmpty ||
        refreshToken is! String ||
        refreshToken.isEmpty ||
        expiresIn == null ||
        expiresIn <= 0) {
      throw AuthFailure(
        invalidCredentials
            ? AuthFailureType.invalidCredentials
            : AuthFailureType.authRequired,
        invalidCredentials
            ? 'Mail.ru отклонил email или пароль приложения.'
            : 'Сессия истекла. Войдите снова.',
      );
    }
    return _OAuthTokens(accessToken, refreshToken, expiresIn);
  }

  Future<String> _requestCsrf(String accessToken) async {
    final uri = apiUrl
        .resolve('tokens/csrf')
        .replace(queryParameters: {'access_token': accessToken});
    final response = await _send('GET', uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const AuthFailure(
        AuthFailureType.authRequired,
        'Не удалось подтвердить сессию Mail.ru.',
      );
    }
    final envelope = _decodeObject(response.bytes);
    final body = envelope['body'];
    final token = body is Map ? body['token'] : null;
    if (token is! String || token.isEmpty) {
      throw const AuthFailure(
        AuthFailureType.invalidResponse,
        'Mail.ru вернул неизвестный формат сессии.',
      );
    }
    return token;
  }

  Future<_HttpResponse> _sendForm(Uri uri, Map<String, String> form) async {
    final encoded = Uri(queryParameters: form).query;
    return _send(
      'POST',
      uri,
      contentType: ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      ),
      bytes: utf8.encode(encoded),
    );
  }

  Future<_HttpResponse> _send(
    String method,
    Uri uri, {
    ContentType? contentType,
    List<int>? bytes,
  }) async {
    try {
      final request = await _httpClient.openUrl(method, uri);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Easy Cloud/1.0 ($clientId)',
      );
      if (contentType != null) request.headers.contentType = contentType;
      if (bytes != null) request.add(bytes);
      final response = await request.close();
      final body = await _readLimited(response);
      return _HttpResponse(response.statusCode, body);
    } on SocketException {
      throw const AuthFailure(
        AuthFailureType.network,
        'Нет соединения с Mail.ru.',
      );
    } on HandshakeException {
      throw const AuthFailure(
        AuthFailureType.network,
        'Не удалось установить защищённое соединение.',
      );
    } on HttpException {
      throw const AuthFailure(
        AuthFailureType.service,
        'Ошибка протокола Mail.ru.',
      );
    }
  }

  Map<String, Object?> _decodeObject(List<int> bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map) return value.cast<String, Object?>();
    } on FormatException {
      // Converted to one stable domain failure below.
    }
    throw const AuthFailure(
      AuthFailureType.invalidResponse,
      'Mail.ru вернул неизвестный формат ответа.',
    );
  }

  @override
  void close() => _httpClient.close(force: true);
}

final class _OAuthTokens {
  const _OAuthTokens(this.accessToken, this.refreshToken, this.expiresIn);

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
}

final class _HttpResponse {
  const _HttpResponse(this.statusCode, this.bytes);

  final int statusCode;
  final List<int> bytes;
}

Future<List<int>> _readLimited(HttpClientResponse response) async {
  const maxBytes = 1024 * 1024;
  final result = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in response) {
    length += chunk.length;
    if (length > maxBytes) {
      throw const AuthFailure(
        AuthFailureType.invalidResponse,
        'Ответ Mail.ru слишком большой.',
      );
    }
    result.add(chunk);
  }
  return result.takeBytes();
}

int? _asInt(Object? value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};
