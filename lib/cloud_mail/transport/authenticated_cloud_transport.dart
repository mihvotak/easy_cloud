import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../core/errors/cloud_failure.dart';
import '../../features/auth/application/auth_repository.dart';
import '../../features/auth/domain/auth_failure.dart';
import '../../features/auth/domain/cloud_session.dart';
import 'cloud_transport.dart';

final class AuthenticatedCloudTransport implements CloudTransport {
  AuthenticatedCloudTransport({
    required AuthRepository authRepository,
    HttpClient? httpClient,
    Uri? apiUrl,
  }) : _authRepository = authRepository,
       _httpClient = httpClient ?? HttpClient(),
       _apiUrl = apiUrl ?? Uri.parse('https://cloud.mail.ru/api/v2/');

  final AuthRepository _authRepository;
  final HttpClient _httpClient;
  final Uri _apiUrl;

  @override
  Future<CloudResponse> get(
    String endpoint, {
    Map<String, String> query = const {},
    bool includeCsrfQuery = false,
  }) async {
    var session = await _freshSession();
    var response = await _sendGet(
      endpoint,
      query,
      session,
      includeCsrfQuery: includeCsrfQuery,
    );
    if (!_isAuthRejected(response)) return _requireHttpSuccess(response);

    try {
      session = await _authRepository.refreshAfterRejection(
        session.accessToken,
      );
    } on AuthFailure catch (failure) {
      throw _fromAuthFailure(failure);
    }
    response = await _sendGet(
      endpoint,
      query,
      session,
      includeCsrfQuery: includeCsrfQuery,
    );
    if (_isAuthRejected(response)) {
      try {
        await _authRepository.logout();
      } on AuthFailure {
        // Runtime state is already signed out even if secure storage failed.
      }
      throw const CloudFailure(
        CloudFailureType.authRequired,
        'Сессия истекла. Войдите снова.',
      );
    }
    return _requireHttpSuccess(response);
  }

  Future<CloudSession> _freshSession() async {
    try {
      return await _authRepository.requireFreshSession();
    } on AuthFailure catch (failure) {
      throw _fromAuthFailure(failure);
    }
  }

  Future<CloudResponse> _sendGet(
    String endpoint,
    Map<String, String> query,
    CloudSession session, {
    required bool includeCsrfQuery,
  }) async {
    final uri = _apiUrl
        .resolve(endpoint)
        .replace(
          queryParameters: {
            ...query,
            if (includeCsrfQuery) 'token': session.csrfToken,
            'access_token': session.accessToken,
          },
        );
    try {
      final request = await _httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.userAgentHeader, 'Easy Cloud/1.0');
      request.headers.set('X-CSRF-Token', session.csrfToken);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      return CloudResponse(
        statusCode: response.statusCode,
        bytes: await _readLimited(
          response,
        ).timeout(const Duration(seconds: 30)),
      );
    } on TimeoutException {
      throw const CloudFailure(
        CloudFailureType.timeout,
        'Mail.ru не ответил вовремя.',
      );
    } on SocketException {
      throw const CloudFailure(
        CloudFailureType.network,
        'Нет соединения с Mail.ru.',
      );
    } on HandshakeException {
      throw const CloudFailure(
        CloudFailureType.network,
        'Не удалось установить защищённое соединение.',
      );
    } on HttpException {
      throw const CloudFailure(
        CloudFailureType.service,
        'Ошибка протокола Mail.ru.',
      );
    }
  }

  CloudResponse _requireHttpSuccess(CloudResponse response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    final type = switch (response.statusCode) {
      HttpStatus.notFound => CloudFailureType.notFound,
      HttpStatus.forbidden => CloudFailureType.permissionDenied,
      _ => CloudFailureType.service,
    };
    throw CloudFailure(
      type,
      type == CloudFailureType.notFound
          ? 'Папка не найдена.'
          : 'Mail.ru вернул ошибку ${response.statusCode}.',
      statusCode: response.statusCode,
    );
  }

  bool _isAuthRejected(CloudResponse response) {
    if (response.statusCode == 401 || response.statusCode == 403) return true;
    try {
      final decoded = response.json;
      if (decoded is! Map) return false;
      final status = _asInt(decoded['status']);
      final error = decoded['error']?.toString().toUpperCase();
      final body = decoded['body']?.toString().toLowerCase();
      return status == 401 ||
          status == 403 ||
          error == 'NOT/AUTHORIZED' ||
          body == 'token' ||
          body == 'user';
    } on FormatException {
      return false;
    }
  }

  @override
  void close() => _httpClient.close(force: true);
}

CloudFailure _fromAuthFailure(AuthFailure failure) =>
    CloudFailure(switch (failure.type) {
      AuthFailureType.network => CloudFailureType.network,
      AuthFailureType.authRequired ||
      AuthFailureType.invalidCredentials => CloudFailureType.authRequired,
      AuthFailureType.invalidResponse => CloudFailureType.invalidResponse,
      _ => CloudFailureType.service,
    }, failure.message);

Future<List<int>> _readLimited(HttpClientResponse response) async {
  const maxBytes = 8 * 1024 * 1024;
  final result = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in response) {
    length += chunk.length;
    if (length > maxBytes) {
      throw const CloudFailure(
        CloudFailureType.invalidResponse,
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
