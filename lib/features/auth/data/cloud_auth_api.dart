import 'dart:async';
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
    this.requestTimeout = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 30),
    this.operationTimeout = const Duration(minutes: 2),
  }) : _httpClient = httpClient ?? HttpClient(),
       oauthUrl = oauthUrl ?? Uri.parse('https://o2.mail.ru/token'),
       apiUrl = apiUrl ?? Uri.parse('https://cloud.mail.ru/api/v2/'),
       _clock = clock ?? DateTime.now {
    if (clientId.isEmpty) throw ArgumentError.value(clientId, 'clientId');
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
    if (readTimeout <= Duration.zero) {
      throw ArgumentError.value(readTimeout, 'readTimeout');
    }
    if (operationTimeout <= Duration.zero) {
      throw ArgumentError.value(operationTimeout, 'operationTimeout');
    }
  }

  final HttpClient _httpClient;
  final String clientId;
  final Uri oauthUrl;
  final Uri apiUrl;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  final Duration readTimeout;
  final Duration operationTimeout;

  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async {
    final deadline = _AuthDeadline(operationTimeout, _clock);
    final tokens = await _requestTokens(
      {
        'client_id': clientId,
        'grant_type': 'password',
        'username': email.trim(),
        'password': password,
      },
      invalidCredentials: true,
      deadline: deadline,
    );
    return _createSession(email.trim(), tokens, deadline: deadline);
  }

  @override
  Future<CloudSession> refresh(CloudSession session) async {
    final deadline = _AuthDeadline(operationTimeout, _clock);
    final tokens = await _requestTokens({
      'client_id': clientId,
      'grant_type': 'refresh_token',
      'refresh_token': session.refreshToken,
    }, deadline: deadline);
    return _createSession(session.email, tokens, deadline: deadline);
  }

  Future<CloudSession> _createSession(
    String email,
    _OAuthTokens tokens, {
    required _AuthDeadline deadline,
  }) async {
    deadline.check();
    final csrf = await _requestCsrf(tokens.accessToken, deadline: deadline);
    deadline.check();
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
    required _AuthDeadline deadline,
  }) async {
    final response = await _sendForm(oauthUrl, form, deadline: deadline);
    deadline.check();
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

  Future<String> _requestCsrf(
    String accessToken, {
    required _AuthDeadline deadline,
  }) async {
    final uri = apiUrl
        .resolve('tokens/csrf')
        .replace(queryParameters: {'access_token': accessToken});
    final response = await _send('GET', uri, deadline: deadline);
    deadline.check();
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

  Future<_HttpResponse> _sendForm(
    Uri uri,
    Map<String, String> form, {
    required _AuthDeadline deadline,
  }) async {
    final encoded = Uri(queryParameters: form).query;
    return _send(
      'POST',
      uri,
      deadline: deadline,
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
    required _AuthDeadline deadline,
    ContentType? contentType,
    List<int>? bytes,
  }) async {
    HttpClientRequest? request;
    try {
      final openedRequest = await _awaitWithAuthDeadline(
        _httpClient.openUrl(method, uri),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      request = openedRequest;
      openedRequest.followRedirects = false;
      openedRequest.headers.set(
        HttpHeaders.userAgentHeader,
        'Easy Cloud/1.0 ($clientId)',
      );
      if (contentType != null) {
        openedRequest.headers.contentType = contentType;
      }
      if (bytes != null) {
        openedRequest.contentLength = bytes.length;
        openedRequest.add(bytes);
      }
      final response = await _awaitWithAuthDeadline(
        openedRequest.close(),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      final body = await _awaitWithAuthDeadline(
        _readLimited(response),
        deadline,
        timeout: readTimeout,
        abort: () => _abortQuietly(request),
      );
      deadline.check();
      return _HttpResponse(response.statusCode, body);
    } on AuthFailure {
      rethrow;
    } on TimeoutException {
      _abortQuietly(request);
      throw const AuthFailure(
        AuthFailureType.timeout,
        'Mail.ru не ответил вовремя.',
      );
    } on SocketException {
      _abortQuietly(request);
      throw const AuthFailure(
        AuthFailureType.network,
        'Нет соединения с Mail.ru.',
      );
    } on HandshakeException {
      _abortQuietly(request);
      throw const AuthFailure(
        AuthFailureType.network,
        'Не удалось установить защищённое соединение.',
      );
    } on HttpException {
      _abortQuietly(request);
      throw const AuthFailure(
        AuthFailureType.service,
        'Ошибка протокола Mail.ru.',
      );
    } finally {
      _abortQuietly(request);
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

final class _AuthDeadline {
  _AuthDeadline(Duration timeout, DateTime Function() clock)
    : expiresAt = clock().add(timeout),
      _clock = clock;

  final DateTime expiresAt;
  final DateTime Function() _clock;

  Duration get remaining {
    final value = expiresAt.difference(_clock());
    if (value <= Duration.zero) {
      throw const AuthFailure(
        AuthFailureType.timeout,
        'Операция входа превысила допустимое время.',
      );
    }
    return value;
  }

  void check() {
    remaining;
  }
}

Future<T> _awaitWithAuthDeadline<T>(
  Future<T> operation,
  _AuthDeadline deadline, {
  required Duration timeout,
  void Function()? abort,
}) async {
  final remaining = deadline.remaining;
  final bounded = remaining < timeout ? remaining : timeout;
  try {
    return await operation.timeout(bounded);
  } on AuthFailure {
    rethrow;
  } on TimeoutException {
    abort?.call();
    throw const AuthFailure(
      AuthFailureType.timeout,
      'Mail.ru не ответил вовремя.',
    );
  }
}

void _abortQuietly(HttpClientRequest? request) {
  try {
    request?.abort();
  } catch (_) {
    // The request may already be closed.
  }
}

int? _asInt(Object? value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};
