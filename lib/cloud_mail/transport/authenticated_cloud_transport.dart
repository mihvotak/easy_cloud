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
    DateTime Function()? clock,
    this.requestTimeout = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 30),
    this.operationTimeout = const Duration(minutes: 2),
  }) : _authRepository = authRepository,
       _httpClient = httpClient ?? HttpClient(),
       _apiUrl = apiUrl ?? Uri.parse('https://cloud.mail.ru/api/v2/'),
       _clock = clock ?? DateTime.now {
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

  final AuthRepository _authRepository;
  final HttpClient _httpClient;
  final Uri _apiUrl;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  final Duration readTimeout;
  final Duration operationTimeout;

  @override
  Future<CloudResponse> get(
    String endpoint, {
    Map<String, String> query = const {},
    bool includeCsrfQuery = false,
  }) async {
    final deadline = _CloudTransportDeadline(operationTimeout, _clock);
    var session = await _awaitWithTransportDeadline(
      _freshSession(),
      deadline,
      timeout: requestTimeout,
    );
    deadline.check();
    var response = await _sendGet(
      endpoint,
      query,
      session,
      includeCsrfQuery: includeCsrfQuery,
      deadline: deadline,
    );
    if (!_isAuthRejected(response)) return _requireHttpSuccess(response);

    try {
      session = await _awaitWithTransportDeadline(
        _authRepository.refreshAfterRejection(session.accessToken),
        deadline,
        timeout: requestTimeout,
      );
    } on AuthFailure catch (failure) {
      throw _fromAuthFailure(failure);
    }
    deadline.check();
    response = await _sendGet(
      endpoint,
      query,
      session,
      includeCsrfQuery: includeCsrfQuery,
      deadline: deadline,
    );
    if (_isAuthRejected(response)) {
      try {
        await _awaitWithTransportDeadline(
          _authRepository.logout(),
          deadline,
          timeout: requestTimeout,
        );
      } on AuthFailure {
        // Runtime state is already signed out even if secure storage failed.
      } on CloudFailure {
        // The failed retry is still an authentication result.
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
    required _CloudTransportDeadline deadline,
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
    HttpClientRequest? request;
    try {
      final openedRequest = await _awaitWithTransportDeadline(
        _httpClient.getUrl(uri),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      request = openedRequest;
      openedRequest.followRedirects = false;
      openedRequest.headers.set(HttpHeaders.userAgentHeader, 'Easy Cloud/1.0');
      openedRequest.headers.set('X-CSRF-Token', session.csrfToken);
      final response = await _awaitWithTransportDeadline(
        openedRequest.close(),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      final bytes = await _awaitWithTransportDeadline(
        _readLimited(response),
        deadline,
        timeout: readTimeout,
        abort: () => _abortQuietly(request),
      );
      deadline.check();
      return CloudResponse(statusCode: response.statusCode, bytes: bytes);
    } on CloudFailure {
      _abortQuietly(request);
      rethrow;
    } on TimeoutException {
      _abortQuietly(request);
      throw const CloudFailure(
        CloudFailureType.timeout,
        'Mail.ru не ответил вовремя.',
      );
    } on SocketException {
      _abortQuietly(request);
      throw const CloudFailure(
        CloudFailureType.network,
        'Нет соединения с Mail.ru.',
      );
    } on HandshakeException {
      _abortQuietly(request);
      throw const CloudFailure(
        CloudFailureType.network,
        'Не удалось установить защищённое соединение.',
      );
    } on HttpException {
      _abortQuietly(request);
      throw const CloudFailure(
        CloudFailureType.service,
        'Ошибка протокола Mail.ru.',
      );
    } finally {
      // Ensure an errored or timed-out response stream cannot outlive the
      // operation. A completed request is already closed and abort is safe.
      _abortQuietly(request);
    }
  }

  CloudResponse _requireHttpSuccess(CloudResponse response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    final type = switch (response.statusCode) {
      HttpStatus.unauthorized => CloudFailureType.authRequired,
      HttpStatus.notFound => CloudFailureType.notFound,
      HttpStatus.forbidden => CloudFailureType.permissionDenied,
      _ => CloudFailureType.service,
    };
    throw CloudFailure(
      type,
      type == CloudFailureType.authRequired
          ? 'Требуется вход в Mail.ru.'
          : type == CloudFailureType.notFound
          ? 'Папка не найдена.'
          : type == CloudFailureType.permissionDenied
          ? 'Mail.ru не разрешил эту операцию.'
          : 'Mail.ru временно недоступен.',
      statusCode: response.statusCode,
    );
  }

  bool _isAuthRejected(CloudResponse response) {
    if (response.statusCode == HttpStatus.unauthorized) return true;
    try {
      final decoded = response.json;
      if (decoded is! Map) return false;
      final status = _asInt(decoded['status']);
      final confirmed =
          _containsAuthMarker(decoded['error']) ||
          _containsAuthMarker(decoded['body']);
      if (status == HttpStatus.unauthorized) return true;
      if (response.statusCode == HttpStatus.forbidden || status == 403) {
        return confirmed;
      }
      return confirmed;
    } on FormatException {
      return false;
    }
  }

  @override
  void close() => _httpClient.close(force: true);
}

CloudFailure _fromAuthFailure(AuthFailure failure) => CloudFailure(
  switch (failure.type) {
    AuthFailureType.network => CloudFailureType.network,
    AuthFailureType.timeout => CloudFailureType.timeout,
    AuthFailureType.authRequired ||
    AuthFailureType.invalidCredentials => CloudFailureType.authRequired,
    AuthFailureType.invalidResponse => CloudFailureType.invalidResponse,
    _ => CloudFailureType.service,
  },
  switch (failure.type) {
    AuthFailureType.timeout => 'Mail.ru не ответил вовремя.',
    AuthFailureType.network => 'Нет соединения с Mail.ru.',
    AuthFailureType.authRequired ||
    AuthFailureType.invalidCredentials => 'Требуется вход в Mail.ru.',
    AuthFailureType.invalidResponse => 'Mail.ru вернул неизвестный ответ.',
    _ => 'Не удалось получить сессию Mail.ru.',
  },
);

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

bool _containsAuthMarker(Object? value) => switch (value) {
  String text => switch (text.trim().toLowerCase()) {
    'token' ||
    'user' ||
    'auth' ||
    'authenticated' ||
    'unauthorized' ||
    'invalid_token' ||
    'expired_token' ||
    'not/authorized' ||
    'not_authorized' => true,
    _ => false,
  },
  Map map => map.values.any(_containsAuthMarker),
  Iterable values => values.any(_containsAuthMarker),
  _ => false,
};

final class _CloudTransportDeadline {
  _CloudTransportDeadline(Duration timeout, DateTime Function() clock)
    : expiresAt = clock().add(timeout),
      _clock = clock;

  final DateTime expiresAt;
  final DateTime Function() _clock;

  Duration get remaining {
    final value = expiresAt.difference(_clock());
    if (value <= Duration.zero) {
      throw const CloudFailure(
        CloudFailureType.timeout,
        'Операция Mail.ru превысила допустимое время.',
      );
    }
    return value;
  }

  void check() {
    remaining;
  }
}

Future<T> _awaitWithTransportDeadline<T>(
  Future<T> operation,
  _CloudTransportDeadline deadline, {
  required Duration timeout,
  void Function()? abort,
}) async {
  final remaining = deadline.remaining;
  final bounded = remaining < timeout ? remaining : timeout;
  try {
    return await operation.timeout(bounded);
  } on CloudFailure {
    rethrow;
  } on TimeoutException {
    abort?.call();
    throw const CloudFailure(
      CloudFailureType.timeout,
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
