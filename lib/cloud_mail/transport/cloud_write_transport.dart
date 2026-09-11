import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../features/auth/application/auth_repository.dart';
import '../../features/auth/domain/auth_failure.dart';
import '../../features/auth/domain/cloud_session.dart';
import '../../features/download/domain/download_cancellation.dart';
import 'cloud_transport.dart';

const defaultCloudWriteDispatcherUrl = 'https://dispatcher.cloud.mail.ru/';
const defaultCloudWriteApiUrl = 'https://cloud.mail.ru/api/v2/';
const defaultCloudWriteClientId = 'cloud-win';
const maxEditorUploadBytes = 10485760;
const defaultCloudWriteResponseLimit = 256 * 1024;
const defaultCloudWriteShardResponseLimit = 64 * 1024;

/// Conflict wire values accepted by `file/add`.
enum CloudWriteConflictMode { strict, rewrite, rename }

/// Identity returned by a verified upload shard response.
final class CloudUploadIdentity {
  const CloudUploadIdentity({required this.hash, required this.size});

  final String hash;
  final int size;
}

/// Canonical path returned by `file/add`.
final class CloudRegisterResult {
  const CloudRegisterResult({
    required this.requestedPath,
    required this.returnedPath,
    required this.conflict,
  });

  final String requestedPath;
  final String returnedPath;
  final CloudWriteConflictMode conflict;
}

/// Result of upload plus registration.  The subsequent stat is deliberately
/// owned by the editor save service, where it can be compared with the local
/// CAS identity.
final class CloudWriteResult {
  const CloudWriteResult({
    required this.identity,
    required this.requestedPath,
    required this.returnedPath,
    required this.conflict,
  });

  final CloudUploadIdentity identity;
  final String requestedPath;
  final String returnedPath;
  final CloudWriteConflictMode conflict;
}

enum CloudWriteFailureType {
  invalidRequest,
  cancelled,
  authRequired,
  network,
  timeout,
  notFound,
  permissionDenied,
  exists,
  invalidResponse,
  integrity,
  service,
  remoteOutcomeUnknown,
}

/// Safe transport failure.  Its string representation never contains a
/// token, shard URL, or remote path.
final class CloudWriteFailure implements Exception {
  const CloudWriteFailure(
    this.type,
    this.message, {
    this.statusCode,
    this.mayHaveSaved = false,
  });

  final CloudWriteFailureType type;
  final String message;
  final int? statusCode;
  final bool mayHaveSaved;

  @override
  String toString() => message;
}

/// Minimal authenticated write capability used by the editor application
/// layer.  A fake can implement this one method without knowing HTTP details.
abstract interface class EditorWriteTransport {
  Future<CloudWriteResult> uploadAndRegister(
    File source, {
    required String remotePath,
    required CloudWriteConflictMode conflict,
    required String expectedHash,
    required int expectedSize,
    required String expectedEmail,
    required int expectedSessionEpoch,
    DownloadCancellationToken? cancellation,
  });

  void close();
}

/// Authenticated streaming implementation of Mail.ru's upload and register
/// protocol.
///
/// It resolves `/u` for every upload attempt, sends the file as a raw bounded
/// stream, and performs at most one auth refresh for one upload/register
/// operation.  The auth retry re-resolves `/u`, so a rotated session cannot
/// accidentally reuse an old shard.
final class CloudMailWriteTransport implements EditorWriteTransport {
  CloudMailWriteTransport({
    required AuthRepository authRepository,
    HttpClient? httpClient,
    Uri? dispatcherUrl,
    Uri? apiUrl,
    this.clientId = defaultCloudWriteClientId,
    this.maxUploadBytes = maxEditorUploadBytes,
    this.maxResponseBytes = defaultCloudWriteResponseLimit,
    this.maxShardResponseBytes = defaultCloudWriteShardResponseLimit,
    this.requestTimeout = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 30),
    this.operationTimeout = const Duration(minutes: 2),
  }) : _authRepository = authRepository,
       _httpClient = httpClient ?? HttpClient(),
       _dispatcherUrl =
           dispatcherUrl ?? Uri.parse(defaultCloudWriteDispatcherUrl),
       _apiUrl = apiUrl ?? Uri.parse(defaultCloudWriteApiUrl) {
    if (clientId.isEmpty) throw ArgumentError.value(clientId, 'clientId');
    if (maxUploadBytes <= 0) {
      throw ArgumentError.value(maxUploadBytes, 'maxUploadBytes');
    }
    if (maxResponseBytes <= 0) {
      throw ArgumentError.value(maxResponseBytes, 'maxResponseBytes');
    }
    if (maxShardResponseBytes <= 0) {
      throw ArgumentError.value(maxShardResponseBytes, 'maxShardResponseBytes');
    }
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
  final Uri _dispatcherUrl;
  final Uri _apiUrl;

  final String clientId;
  final int maxUploadBytes;
  final int maxResponseBytes;
  final int maxShardResponseBytes;
  final Duration requestTimeout;
  final Duration readTimeout;
  final Duration operationTimeout;

  bool _closed = false;

  @override
  Future<CloudWriteResult> uploadAndRegister(
    File source, {
    required String remotePath,
    required CloudWriteConflictMode conflict,
    required String expectedHash,
    required int expectedSize,
    required String expectedEmail,
    required int expectedSessionEpoch,
    DownloadCancellationToken? cancellation,
  }) async {
    _ensureOpen();
    final deadline = _CloudWriteDeadline(operationTimeout);
    final path = _safeRemoteFilePath(remotePath);
    final hash = _normalizeHash(expectedHash);
    _validateSize(expectedSize);
    final scope = await _createScope(
      expectedEmail: expectedEmail,
      expectedEpoch: expectedSessionEpoch,
      cancellation: cancellation,
      deadline: deadline,
    );
    _validateSource(source, expectedSize);

    CloudUploadIdentity? identity;
    var registerPath = path;
    while (true) {
      cancellation?.throwIfCancelled();
      _ensureScope(scope, cancellation);
      try {
        if (identity == null) {
          final shard = await _resolveUploadShard(
            scope,
            cancellation,
            deadline,
          );
          identity = await _uploadOnce(
            source,
            shard,
            scope,
            expectedHash: hash,
            expectedSize: expectedSize,
            cancellation: cancellation,
            deadline: deadline,
          );
        }
        _ensureScope(scope, cancellation);
        final registration = await _registerOnce(
          remotePath: registerPath,
          conflict: conflict,
          identity: identity,
          scope: scope,
          cancellation: cancellation,
          deadline: deadline,
        );
        return CloudWriteResult(
          identity: identity,
          requestedPath: path,
          returnedPath: registration.returnedPath,
          conflict: conflict,
        );
      } on _CloudWriteAuthRejected {
        if (scope.authRetryUsed) {
          await _logoutIfCurrent(scope.session);
          throw const CloudWriteFailure(
            CloudWriteFailureType.authRequired,
            'Сессия истекла. Войдите снова.',
          );
        }
        scope.authRetryUsed = true;
        await _refreshScope(scope, cancellation, deadline);
        // If upload already completed, keep its verified identity and only
        // retry registration.  If the rejection happened before upload, the
        // next loop resolves a fresh shard and streams once more.
      }
    }
  }

  /// Uploads one file without registration.  This is useful to protocol
  /// callers and uses the same bounded auth/shard behavior as a full save.
  Future<CloudUploadIdentity> upload(
    File source, {
    required String expectedHash,
    required int expectedSize,
    String? expectedEmail,
    int? expectedSessionEpoch,
    DownloadCancellationToken? cancellation,
  }) async {
    _ensureOpen();
    final deadline = _CloudWriteDeadline(operationTimeout);
    final hash = _normalizeHash(expectedHash);
    _validateSize(expectedSize);
    final scope = await _createScope(
      expectedEmail: expectedEmail,
      expectedEpoch: expectedSessionEpoch,
      cancellation: cancellation,
      deadline: deadline,
    );
    _validateSource(source, expectedSize);
    while (true) {
      try {
        final shard = await _resolveUploadShard(scope, cancellation, deadline);
        final result = await _uploadOnce(
          source,
          shard,
          scope,
          expectedHash: hash,
          expectedSize: expectedSize,
          cancellation: cancellation,
          deadline: deadline,
        );
        _ensureScope(scope, cancellation);
        deadline.check();
        return result;
      } on _CloudWriteAuthRejected {
        if (scope.authRetryUsed) {
          await _logoutIfCurrent(scope.session);
          throw const CloudWriteFailure(
            CloudWriteFailureType.authRequired,
            'Сессия истекла. Войдите снова.',
          );
        }
        scope.authRetryUsed = true;
        await _refreshScope(scope, cancellation, deadline);
      }
    }
  }

  /// Registers a previously uploaded identity without uploading bytes.
  Future<CloudRegisterResult> register({
    required String remotePath,
    required CloudWriteConflictMode conflict,
    required String hash,
    required int size,
    String? expectedEmail,
    int? expectedSessionEpoch,
    DownloadCancellationToken? cancellation,
  }) async {
    _ensureOpen();
    final deadline = _CloudWriteDeadline(operationTimeout);
    final path = _safeRemoteFilePath(remotePath);
    final identity = CloudUploadIdentity(
      hash: _normalizeHash(hash),
      size: size,
    );
    _validateSize(size);
    final scope = await _createScope(
      expectedEmail: expectedEmail,
      expectedEpoch: expectedSessionEpoch,
      cancellation: cancellation,
      deadline: deadline,
    );
    while (true) {
      try {
        final result = await _registerOnce(
          remotePath: path,
          conflict: conflict,
          identity: identity,
          scope: scope,
          cancellation: cancellation,
          deadline: deadline,
        );
        _ensureScope(scope, cancellation);
        deadline.check();
        return result;
      } on _CloudWriteAuthRejected {
        if (scope.authRetryUsed) {
          await _logoutIfCurrent(scope.session);
          throw const CloudWriteFailure(
            CloudWriteFailureType.authRequired,
            'Сессия истекла. Войдите снова.',
          );
        }
        scope.authRetryUsed = true;
        await _refreshScope(scope, cancellation, deadline);
      }
    }
  }

  Future<CloudRegisterResult> _registerOnce({
    required String remotePath,
    required CloudWriteConflictMode conflict,
    required CloudUploadIdentity identity,
    required _CloudWriteScope scope,
    required DownloadCancellationToken? cancellation,
    required _CloudWriteDeadline deadline,
  }) async {
    deadline.check();
    _ensureScope(scope, cancellation);
    final uri = _apiUrl
        .resolve('file/add')
        .replace(queryParameters: {'access_token': scope.session.accessToken});
    final form = <String, String>{
      'api': '2',
      'conflict': conflict.name,
      'home': remotePath,
      'hash': identity.hash,
      'size': '${identity.size}',
    };
    final response = await _sendForm(
      uri,
      form,
      csrfToken: scope.session.csrfToken,
      cancellation: cancellation,
      deadline: deadline,
    );
    _ensureScope(scope, cancellation);
    deadline.check();
    if (_isAuthRejected(response)) throw const _CloudWriteAuthRejected();
    late final CloudRegisterResult result;
    try {
      result = parseCloudFileAddResponse(
        response,
        requestedPath: remotePath,
        conflict: conflict,
      );
    } on CloudWriteFailure catch (failure) {
      if (failure.type == CloudWriteFailureType.invalidResponse) {
        throw _remoteOutcomeUnknownFailure(statusCode: failure.statusCode);
      }
      rethrow;
    }
    _ensureScope(scope, cancellation);
    deadline.check();
    return result;
  }

  bool _isAuthRejected(CloudResponse response) {
    final envelope = _decodeJsonMap(response.bytes);
    final apiStatus = envelope == null
        ? null
        : _integerStatus(envelope['status']);
    final errorCode = envelope == null
        ? _plainErrorCode(response.bytes)
        : _fileAddErrorCode(envelope);
    if (response.statusCode == HttpStatus.unauthorized ||
        apiStatus == HttpStatus.unauthorized) {
      return true;
    }
    if (response.statusCode == HttpStatus.forbidden ||
        apiStatus == HttpStatus.forbidden) {
      // A 403 is permission-denied unless the body explicitly confirms an
      // authentication marker. Refreshing on an arbitrary 403 can repeat a
      // read-only/ACL failure and needlessly rotate a valid session.
      return _containsAuthErrorCode(envelope?['error']) ||
          _containsAuthErrorCode(envelope?['body']) ||
          _isAuthErrorCode(errorCode);
    }
    return _containsAuthErrorCode(envelope?['error']) ||
        _containsAuthErrorCode(envelope?['body']) ||
        _isAuthErrorCode(errorCode);
  }

  Future<CloudUploadIdentity> _uploadOnce(
    File source,
    Uri shard,
    _CloudWriteScope scope, {
    required String expectedHash,
    required int expectedSize,
    required DownloadCancellationToken? cancellation,
    required _CloudWriteDeadline deadline,
  }) async {
    deadline.check();
    _ensureScope(scope, cancellation);
    final uri = shard
        .replace(queryParameters: {})
        .replace(
          queryParameters: {
            'client_id': clientId,
            'token': scope.session.accessToken,
          },
        );
    final response = await _sendFile(
      uri,
      source,
      expectedSize: expectedSize,
      cancellation: cancellation,
      deadline: deadline,
    );
    _ensureScope(scope, cancellation);
    deadline.check();
    if (_isAuthRejected(response)) throw const _CloudWriteAuthRejected();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.created) {
      throw _failureForHttpStatus(response.statusCode, 'Загрузка');
    }
    final result = parseCloudUploadShardResponse(
      _decodeText(response.bytes),
      expectedSize: expectedSize,
    );
    _ensureScope(scope, cancellation);
    deadline.check();
    if (result.hash != expectedHash) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.integrity,
        'Хеш загруженного файла не совпадает с локальным содержимым.',
      );
    }
    final identity = CloudUploadIdentity(hash: result.hash, size: expectedSize);
    _ensureScope(scope, cancellation);
    deadline.check();
    return identity;
  }

  Future<Uri> _resolveUploadShard(
    _CloudWriteScope scope,
    DownloadCancellationToken? cancellation,
    _CloudWriteDeadline deadline,
  ) async {
    deadline.check();
    _ensureScope(scope, cancellation);
    final uri = _dispatcherUrl
        .resolve('u')
        .replace(queryParameters: {'token': scope.session.accessToken});
    final response = await _sendSimple(
      'GET',
      uri,
      cancellation: cancellation,
      maxBytes: maxShardResponseBytes,
      deadline: deadline,
    );
    _ensureScope(scope, cancellation);
    deadline.check();
    if (_isAuthRejected(response)) throw const _CloudWriteAuthRejected();
    if (response.statusCode != HttpStatus.ok) {
      throw _failureForHttpStatus(response.statusCode, 'Диспетчер');
    }

    final shard = parseCloudWriteDispatcherResponse(
      _decodeText(response.bytes),
    );
    _ensureScope(scope, cancellation);
    deadline.check();
    return shard;
  }

  Future<_CloudWriteScope> _createScope({
    required String? expectedEmail,
    required int? expectedEpoch,
    required DownloadCancellationToken? cancellation,
    required _CloudWriteDeadline deadline,
  }) async {
    deadline.check();
    cancellation?.throwIfCancelled();
    final startEpoch = _authRepository.sessionEpoch;
    final session = await _awaitWithDeadline(
      _freshSession(),
      deadline,
      timeout: requestTimeout,
    );
    final epoch = expectedEpoch ?? startEpoch;
    final email = _normalizeEmail(expectedEmail ?? session.email);
    final scope = _CloudWriteScope(
      session: session,
      email: email,
      epoch: epoch,
    );
    _ensureScope(scope, cancellation);
    deadline.check();
    return scope;
  }

  Future<CloudSession> _freshSession() async {
    try {
      return await _authRepository.requireFreshSession();
    } on AuthFailure catch (failure) {
      throw _fromAuthFailure(failure);
    }
  }

  Future<void> _refreshScope(
    _CloudWriteScope scope,
    DownloadCancellationToken? cancellation,
    _CloudWriteDeadline deadline,
  ) async {
    deadline.check();
    _ensureScope(scope, cancellation);
    try {
      final refreshed = await _awaitWithDeadline(
        _authRepository.refreshAfterRejection(scope.session.accessToken),
        deadline,
        timeout: requestTimeout,
      );
      if (_authRepository.sessionEpoch != scope.epoch ||
          _normalizeEmail(refreshed.email) != scope.email) {
        throw const CloudWriteFailure(
          CloudWriteFailureType.cancelled,
          'Операция сохранения отменена при смене аккаунта.',
        );
      }
      scope.session = refreshed;
      _ensureScope(scope, cancellation);
      deadline.check();
    } on AuthFailure catch (failure) {
      throw _fromAuthFailure(failure);
    }
  }

  Future<void> _logoutIfCurrent(CloudSession rejectedSession) async {
    if (_authRepository.currentSession?.accessToken !=
        rejectedSession.accessToken) {
      return;
    }
    try {
      await _authRepository.logout();
    } on AuthFailure {
      // AuthRepository has already cleared its in-memory session.
    }
  }

  Future<CloudResponse> _sendFile(
    Uri uri,
    File source, {
    required int expectedSize,
    required DownloadCancellationToken? cancellation,
    required _CloudWriteDeadline deadline,
  }) async {
    HttpClientRequest? request;
    StreamSubscription<void>? cancellationSubscription;
    try {
      cancellation?.throwIfCancelled();
      final openedRequest = await _awaitWithDeadline(
        _httpClient.openUrl('PUT', uri),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      request = openedRequest;
      openedRequest.followRedirects = false;
      openedRequest.headers.set(HttpHeaders.userAgentHeader, clientId);
      openedRequest.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/octet-stream',
      );
      openedRequest.contentLength = expectedSize;
      if (cancellation != null) {
        cancellationSubscription = cancellation.cancellations.listen((_) {
          _abortQuietly(request);
        });
      }
      cancellation?.throwIfCancelled();
      await _awaitWithDeadline(
        openedRequest.addStream(source.openRead()),
        deadline,
        timeout: readTimeout,
        abort: () => _abortQuietly(request),
      );
      cancellation?.throwIfCancelled();
      final response = await _awaitWithDeadline(
        openedRequest.close(),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      final bytes = await _awaitWithDeadline(
        _readLimited(response, maxResponseBytes),
        deadline,
        timeout: readTimeout,
        abort: () => _abortQuietly(request),
      );
      cancellation?.throwIfCancelled();
      return CloudResponse(statusCode: response.statusCode, bytes: bytes);
    } catch (error) {
      _abortQuietly(request);
      if (cancellation?.isCancelled == true) {
        throw const CloudWriteFailure(
          CloudWriteFailureType.cancelled,
          'Операция сохранения отменена.',
        );
      }
      throw _mapTransportError(error, operation: 'Загрузка');
    } finally {
      await cancellationSubscription?.cancel();
    }
  }

  Future<CloudResponse> _sendForm(
    Uri uri,
    Map<String, String> form, {
    required String csrfToken,
    required DownloadCancellationToken? cancellation,
    required _CloudWriteDeadline deadline,
  }) async {
    final encoded = Uri(queryParameters: form).query;
    final bytes = utf8.encode(encoded);
    HttpClientRequest? request;
    var requestSubmitted = false;
    StreamSubscription<void>? cancellationSubscription;
    try {
      cancellation?.throwIfCancelled();
      final openedRequest = await _awaitWithDeadline(
        _httpClient.openUrl('POST', uri),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      request = openedRequest;
      openedRequest.followRedirects = false;
      openedRequest.headers.set(HttpHeaders.userAgentHeader, clientId);
      openedRequest.headers.set('X-CSRF-Token', csrfToken);
      openedRequest.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      openedRequest.contentLength = bytes.length;
      if (cancellation != null) {
        cancellationSubscription = cancellation.cancellations.listen((_) {
          _abortQuietly(request);
        });
      }
      cancellation?.throwIfCancelled();
      requestSubmitted = true;
      openedRequest.add(bytes);
      final response = await _awaitWithDeadline(
        openedRequest.close(),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      final responseBytes = await _awaitWithDeadline(
        _readLimited(response, maxResponseBytes),
        deadline,
        timeout: readTimeout,
        abort: () => _abortQuietly(request),
      );
      cancellation?.throwIfCancelled();
      return CloudResponse(
        statusCode: response.statusCode,
        bytes: responseBytes,
      );
    } catch (error) {
      _abortQuietly(request);
      if (cancellation?.isCancelled == true) {
        if (requestSubmitted) {
          throw _remoteOutcomeUnknownFailure();
        }
        throw const CloudWriteFailure(
          CloudWriteFailureType.cancelled,
          'Операция сохранения отменена.',
        );
      }
      final failure = _mapTransportError(error, operation: 'Регистрация');
      if (requestSubmitted && _mayHaveRemoteEffect(failure)) {
        throw _remoteOutcomeUnknownFailure(statusCode: failure.statusCode);
      }
      throw failure;
    } finally {
      await cancellationSubscription?.cancel();
    }
  }

  Future<CloudResponse> _sendSimple(
    String method,
    Uri uri, {
    required DownloadCancellationToken? cancellation,
    required int maxBytes,
    required _CloudWriteDeadline deadline,
  }) async {
    HttpClientRequest? request;
    StreamSubscription<void>? cancellationSubscription;
    try {
      cancellation?.throwIfCancelled();
      final openedRequest = await _awaitWithDeadline(
        _httpClient.openUrl(method, uri),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      request = openedRequest;
      openedRequest.followRedirects = false;
      openedRequest.headers.set(HttpHeaders.userAgentHeader, clientId);
      if (cancellation != null) {
        cancellationSubscription = cancellation.cancellations.listen((_) {
          _abortQuietly(request);
        });
      }
      cancellation?.throwIfCancelled();
      final response = await _awaitWithDeadline(
        openedRequest.close(),
        deadline,
        timeout: requestTimeout,
        abort: () => _abortQuietly(request),
      );
      final bytes = await _awaitWithDeadline(
        _readLimited(response, maxBytes),
        deadline,
        timeout: readTimeout,
        abort: () => _abortQuietly(request),
      );
      cancellation?.throwIfCancelled();
      return CloudResponse(statusCode: response.statusCode, bytes: bytes);
    } catch (error) {
      _abortQuietly(request);
      if (cancellation?.isCancelled == true) {
        throw const CloudWriteFailure(
          CloudWriteFailureType.cancelled,
          'Операция сохранения отменена.',
        );
      }
      throw _mapTransportError(error, operation: 'Запрос');
    } finally {
      await cancellationSubscription?.cancel();
    }
  }

  Future<List<int>> _readLimited(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    if (response.contentLength >= 0 && response.contentLength > maxBytes) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.invalidResponse,
        'Ответ Mail.ru слишком большой.',
      );
    }
    final result = BytesBuilder(copy: false);
    var length = 0;
    try {
      await for (final chunk in response.timeout(readTimeout)) {
        length += chunk.length;
        if (length > maxBytes) {
          throw const CloudWriteFailure(
            CloudWriteFailureType.invalidResponse,
            'Ответ Mail.ru слишком большой.',
          );
        }
        result.add(chunk);
      }
    } on CloudWriteFailure {
      rethrow;
    } on TimeoutException {
      throw const CloudWriteFailure(
        CloudWriteFailureType.timeout,
        'Mail.ru не ответил вовремя.',
      );
    } on FormatException {
      throw const CloudWriteFailure(
        CloudWriteFailureType.invalidResponse,
        'Mail.ru вернул ответ в неизвестной кодировке.',
      );
    }
    return result.takeBytes();
  }

  void _validateSource(File source, int expectedSize) {
    try {
      if (!source.existsSync()) {
        throw const CloudWriteFailure(
          CloudWriteFailureType.invalidRequest,
          'Локальное содержимое недоступно.',
        );
      }
      final actualSize = source.lengthSync();
      if (actualSize != expectedSize) {
        throw const CloudWriteFailure(
          CloudWriteFailureType.integrity,
          'Размер локального содержимого изменился.',
        );
      }
    } on CloudWriteFailure {
      rethrow;
    } on FileSystemException {
      throw CloudWriteFailure(
        CloudWriteFailureType.invalidRequest,
        'Локальное содержимое недоступно.',
      );
    }
  }

  void _validateSize(int size) {
    if (size < 0 || size > maxUploadBytes) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.invalidRequest,
        'Размер редактора превышает допустимый предел.',
      );
    }
  }

  String _normalizeHash(String hash) {
    final normalized = hash.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{40}$').hasMatch(normalized)) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.invalidRequest,
        'Локальная идентичность содержимого недействительна.',
      );
    }
    return normalized;
  }

  String _safeRemoteFilePath(String value) {
    if (value.trim() != value) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.invalidRequest,
        'Путь удалённого файла недействителен.',
      );
    }
    final path = value;
    if (path.length < 2 ||
        path.length > 4096 ||
        !path.startsWith('/') ||
        path.startsWith('//') ||
        path.endsWith('/') ||
        path.contains('\\') ||
        path.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.invalidRequest,
        'Путь удалённого файла недействителен.',
      );
    }
    final segments = path.substring(1).split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.invalidRequest,
        'Путь удалённого файла недействителен.',
      );
    }
    return '/${segments.join('/')}';
  }

  String _normalizeEmail(String email) {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.authRequired,
        'Требуется вход в Mail.ru.',
      );
    }
    return normalized;
  }

  void _ensureScope(
    _CloudWriteScope scope,
    DownloadCancellationToken? cancellation,
  ) {
    cancellation?.throwIfCancelled();
    final current = _authRepository.currentSession;
    if (_authRepository.sessionEpoch != scope.epoch ||
        current == null ||
        _normalizeEmail(current.email) != scope.email) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.cancelled,
        'Операция сохранения отменена при смене аккаунта.',
      );
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Cloud write transport is closed.');
  }

  void _abortQuietly(HttpClientRequest? request) {
    try {
      request?.abort();
    } catch (_) {
      // The request may already be closed.
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _httpClient.close(force: true);
  }
}

/// Parses the only upload response grammars accepted by the client.
UploadShardResult parseCloudUploadShardResponse(
  String response, {
  required int expectedSize,
}) {
  if (expectedSize < 0) {
    throw const CloudWriteFailure(
      CloudWriteFailureType.invalidRequest,
      'Размер локального содержимого недействителен.',
    );
  }
  final match = RegExp(
    r'^([0-9a-fA-F]{40})(?:;([0-9]+))?$',
  ).firstMatch(response.trim());
  if (match == null) {
    throw const CloudWriteFailure(
      CloudWriteFailureType.invalidResponse,
      'Шард загрузки вернул неизвестный результат.',
    );
  }
  final sizeText = match.group(2);
  int? reportedSize;
  if (sizeText != null) {
    reportedSize = int.tryParse(sizeText);
    if (reportedSize == null || reportedSize != expectedSize) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.integrity,
        'Размер загруженного файла не совпадает с локальным содержимым.',
      );
    }
  }
  return UploadShardResult(
    hash: match.group(1)!.toUpperCase(),
    size: reportedSize,
  );
}

/// Parses and validates one `file/add` response.  The response body must
/// contain the canonical returned file path; no client-side rename is ever
/// synthesized.
CloudRegisterResult parseCloudFileAddResponse(
  CloudResponse response, {
  required String requestedPath,
  required CloudWriteConflictMode conflict,
}) {
  final requested = _safePathForParser(requestedPath);
  if (requested == null) {
    throw const CloudWriteFailure(
      CloudWriteFailureType.invalidRequest,
      'Путь удалённого файла недействителен.',
    );
  }
  final envelope = _decodeJsonMap(response.bytes);
  final apiStatus = envelope == null
      ? null
      : _integerStatus(envelope['status']);
  final errorCode = envelope == null
      ? _plainErrorCode(response.bytes)
      : _fileAddErrorCode(envelope);

  final confirmedAuth = _isConfirmedAuthResponse(
    response,
    envelope,
    apiStatus,
    errorCode,
  );
  if (confirmedAuth) {
    throw const CloudWriteFailure(
      CloudWriteFailureType.authRequired,
      'Сессия истекла. Войдите снова.',
    );
  }
  final mappedError = _mapFileAddError(errorCode);
  if (mappedError != null) {
    throw CloudWriteFailure(
      mappedError.type,
      mappedError.message,
      statusCode: response.statusCode,
    );
  }
  if (envelope != null && _hasFileAddError(envelope)) {
    throw CloudWriteFailure(
      CloudWriteFailureType.service,
      'Mail.ru не принял регистрацию файла.',
      statusCode: response.statusCode,
    );
  }
  if (response.statusCode == HttpStatus.forbidden || apiStatus == 403) {
    // Unknown 403 responses are permission failures by default. Authentication
    // refresh is allowed only after a confirmed marker in the body.
    throw CloudWriteFailure(
      CloudWriteFailureType.permissionDenied,
      'Mail.ru не разрешил изменить файл.',
      statusCode: response.statusCode,
    );
  }
  if (apiStatus != null && (apiStatus < 200 || apiStatus > 299)) {
    throw CloudWriteFailure(
      CloudWriteFailureType.service,
      'Mail.ru не принял регистрацию файла.',
      statusCode: response.statusCode,
    );
  }
  if (response.statusCode < 200 || response.statusCode > 299) {
    throw _failureForHttpStatus(response.statusCode, 'Регистрация');
  }
  if (envelope == null ||
      envelope['status'] is! int ||
      apiStatus == null ||
      apiStatus < 200 ||
      apiStatus > 299 ||
      apiStatus != response.statusCode ||
      envelope['body'] is! String) {
    throw const CloudWriteFailure(
      CloudWriteFailureType.invalidResponse,
      'Mail.ru вернул неизвестный результат регистрации.',
    );
  }
  final returned = _extractReturnedPath(envelope['body']);
  if (returned == null) {
    throw const CloudWriteFailure(
      CloudWriteFailureType.invalidResponse,
      'Mail.ru вернул неизвестный результат регистрации.',
    );
  }
  if (conflict != CloudWriteConflictMode.rename && returned != requested) {
    throw const CloudWriteFailure(
      CloudWriteFailureType.invalidResponse,
      'Mail.ru вернул другой путь файла.',
    );
  }
  if (conflict == CloudWriteConflictMode.rename &&
      (returned == requested ||
          editorParentForParser(returned) !=
              editorParentForParser(requested))) {
    throw const CloudWriteFailure(
      CloudWriteFailureType.invalidResponse,
      'Mail.ru вернул недопустимый путь переименованного файла.',
    );
  }
  return CloudRegisterResult(
    requestedPath: requested,
    returnedPath: returned,
    conflict: conflict,
  );
}

/// Trusted shard policy shared by upload tests and production transport.
bool isTrustedCloudWriteShard(Uri shard) {
  final scheme = shard.scheme.toLowerCase();
  final host = shard.host.toLowerCase();
  final trustedHost =
      host == 'cloud.mail.ru' ||
      host.endsWith('.cloud.mail.ru') ||
      host == 'datacloudmail.ru' ||
      host.endsWith('.datacloudmail.ru');
  return shard.userInfo.isEmpty &&
      shard.query.isEmpty &&
      shard.fragment.isEmpty &&
      scheme == 'https' &&
      trustedHost;
}

/// Parses the live `/u` grammar: a shard URL followed by optional dispatcher
/// metadata fields such as IP and selection count.
Uri parseCloudWriteDispatcherResponse(String response) {
  final body = response.trim();
  final firstField = body.isEmpty ? '' : body.split(RegExp(r'\s+')).first;
  final shard = Uri.tryParse(firstField);
  if (shard == null || !isTrustedCloudWriteShard(shard)) {
    throw const CloudWriteFailure(
      CloudWriteFailureType.invalidResponse,
      'Диспетчер вернул неизвестный адрес загрузки.',
    );
  }
  return shard;
}

final class UploadShardResult {
  const UploadShardResult({required this.hash, required this.size});

  final String hash;
  final int? size;
}

final class _CloudWriteScope {
  _CloudWriteScope({
    required this.session,
    required this.email,
    required this.epoch,
  });

  CloudSession session;
  final String email;
  final int epoch;
  bool authRetryUsed = false;
}

final class _CloudWriteAuthRejected implements Exception {
  const _CloudWriteAuthRejected();
}

final class _CloudWriteDeadline {
  _CloudWriteDeadline(Duration timeout)
    : expiresAt = DateTime.now().add(timeout);

  final DateTime expiresAt;

  Duration get remaining {
    final value = expiresAt.difference(DateTime.now());
    if (value <= Duration.zero) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.timeout,
        'Операция сохранения превысила допустимое время.',
      );
    }
    return value;
  }

  void check() {
    final now = DateTime.now();
    if (!now.isBefore(expiresAt)) {
      throw const CloudWriteFailure(
        CloudWriteFailureType.timeout,
        'Операция сохранения превысила допустимое время.',
      );
    }
  }
}

final class _MappedFileAddError {
  const _MappedFileAddError(this.type, this.message);

  final CloudWriteFailureType type;
  final String message;
}

String _decodeText(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const CloudWriteFailure(
      CloudWriteFailureType.invalidResponse,
      'Mail.ru вернул ответ в неизвестной кодировке.',
    );
  }
}

Map<String, Object?>? _decodeJsonMap(List<int> bytes) {
  try {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is Map) return value.cast<String, Object?>();
  } on FormatException {
    return null;
  }
  return null;
}

String? _plainErrorCode(List<int> bytes) {
  try {
    final text = utf8.decode(bytes).trim();
    return RegExp(r'^[a-zA-Z_/]+$').hasMatch(text) ? text : null;
  } on FormatException {
    return null;
  }
}

String? _fileAddErrorCode(Map<String, Object?> envelope) {
  final topLevelError = envelope['error'];
  if (topLevelError is String) return topLevelError;
  final body = envelope['body'];
  if (body is String && _safePathForParser(body) == null) return body;
  if (body is! Map) return null;
  final directError = body['error'];
  if (directError is String) return directError;
  for (final key in const ['home', 'weblink', 'invite_email', 'path']) {
    final value = body[key];
    if (value is Map && value['error'] is String) {
      return value['error'] as String;
    }
  }
  return null;
}

bool _hasFileAddError(Map<String, Object?> envelope) {
  final error = envelope['error'];
  if (error is String) return error.trim().isNotEmpty;
  if (error is Map || error is Iterable) return true;

  final body = envelope['body'];
  if (body is String) return _safePathForParser(body) == null;
  if (body is! Map) return false;
  if (body['error'] != null) return true;
  return const ['home', 'weblink', 'invite_email', 'path'].any((key) {
    final value = body[key];
    return value is Map && value['error'] != null;
  });
}

String? _extractReturnedPath(Object? body) {
  Object? candidate = body;
  if (body is Map) candidate = body['home'] ?? body['path'];
  if (candidate is! String) return null;
  return _safePathForParser(candidate);
}

_MappedFileAddError? _mapFileAddError(String? value) {
  final normalized = value?.trim().toLowerCase();
  return switch (normalized) {
    'exists' => const _MappedFileAddError(
      CloudWriteFailureType.exists,
      'Удалённый файл уже существует.',
    ),
    'token' ||
    'user' ||
    'not/authorized' ||
    'not_authorized' => const _MappedFileAddError(
      CloudWriteFailureType.authRequired,
      'Сессия истекла. Войдите снова.',
    ),
    'readonly' ||
    'read_only' ||
    'permission' ||
    'permission_denied' ||
    'access_denied' ||
    'forbidden' => const _MappedFileAddError(
      CloudWriteFailureType.permissionDenied,
      'Mail.ru не разрешил изменить файл.',
    ),
    'required' || 'invalid' => const _MappedFileAddError(
      CloudWriteFailureType.invalidRequest,
      'Mail.ru отклонил параметры файла.',
    ),
    'not_exists' || 'content_not_found' => const _MappedFileAddError(
      CloudWriteFailureType.service,
      'Загруженное содержимое недоступно для регистрации.',
    ),
    'overquota' || 'quota_exceeded' => const _MappedFileAddError(
      CloudWriteFailureType.service,
      'Недостаточно места в облаке.',
    ),
    null => null,
    _ => null,
  };
}

bool _isConfirmedAuthResponse(
  CloudResponse response,
  Map<String, Object?>? envelope,
  int? apiStatus,
  String? errorCode,
) {
  if (response.statusCode == HttpStatus.unauthorized ||
      apiStatus == HttpStatus.unauthorized) {
    return true;
  }
  final bodyContainsAuth =
      _containsAuthErrorCode(envelope?['error']) ||
      _containsAuthErrorCode(envelope?['body']) ||
      _isAuthErrorCode(errorCode);
  if (response.statusCode == HttpStatus.forbidden || apiStatus == 403) {
    return bodyContainsAuth;
  }
  return bodyContainsAuth;
}

bool _isAuthErrorCode(String? code) => switch (code?.trim().toLowerCase()) {
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
};

bool _containsAuthErrorCode(Object? value) => switch (value) {
  String text => _isAuthErrorCode(text),
  Map map => map.values.any(_containsAuthErrorCode),
  Iterable values => values.any(_containsAuthErrorCode),
  _ => false,
};

String? _safePathForParser(String value) {
  if (value.trim() != value) return null;
  final path = value;
  if (path.length < 2 ||
      path.length > 4096 ||
      !path.startsWith('/') ||
      path.startsWith('//') ||
      path.endsWith('/') ||
      path.contains('\\') ||
      path.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return null;
  }
  final segments = path.substring(1).split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    return null;
  }
  return '/${segments.join('/')}';
}

String? editorParentForParser(String value) {
  final path = _safePathForParser(value);
  if (path == null) return null;
  final separator = path.lastIndexOf('/');
  return separator <= 0 ? '/' : path.substring(0, separator);
}

CloudWriteFailure _failureForHttpStatus(int statusCode, String operation) {
  final type = switch (statusCode) {
    HttpStatus.notFound => CloudWriteFailureType.notFound,
    HttpStatus.forbidden => CloudWriteFailureType.permissionDenied,
    _ => CloudWriteFailureType.service,
  };
  return CloudWriteFailure(
    type,
    type == CloudWriteFailureType.notFound
        ? 'Файл не найден.'
        : '$operation завершилась с ошибкой Mail.ru.',
    statusCode: statusCode,
  );
}

CloudWriteFailure _fromAuthFailure(AuthFailure failure) => CloudWriteFailure(
  switch (failure.type) {
    AuthFailureType.network => CloudWriteFailureType.network,
    AuthFailureType.timeout => CloudWriteFailureType.timeout,
    AuthFailureType.authRequired ||
    AuthFailureType.invalidCredentials => CloudWriteFailureType.authRequired,
    AuthFailureType.invalidResponse => CloudWriteFailureType.invalidResponse,
    AuthFailureType.service ||
    AuthFailureType.secureStorage => CloudWriteFailureType.service,
  },
  switch (failure.type) {
    AuthFailureType.authRequired ||
    AuthFailureType.invalidCredentials => 'Требуется вход в Mail.ru.',
    AuthFailureType.network => 'Нет соединения с Mail.ru.',
    _ => 'Не удалось обновить сессию Mail.ru.',
  },
);

CloudWriteFailure _mapTransportError(
  Object error, {
  required String operation,
}) => switch (error) {
  CloudWriteFailure failure => failure,
  TimeoutException() => const CloudWriteFailure(
    CloudWriteFailureType.timeout,
    'Mail.ru не ответил вовремя.',
  ),
  SocketException() || HandshakeException() => const CloudWriteFailure(
    CloudWriteFailureType.network,
    'Нет соединения с Mail.ru.',
  ),
  HttpException() => const CloudWriteFailure(
    CloudWriteFailureType.service,
    'Ошибка протокола Mail.ru.',
  ),
  _ => CloudWriteFailure(
    CloudWriteFailureType.service,
    'Не удалось выполнить операцию сохранения.',
  ),
};

bool _mayHaveRemoteEffect(CloudWriteFailure failure) =>
    failure.type == CloudWriteFailureType.network ||
    failure.type == CloudWriteFailureType.timeout ||
    failure.type == CloudWriteFailureType.service ||
    failure.type == CloudWriteFailureType.invalidResponse;

CloudWriteFailure _remoteOutcomeUnknownFailure({int? statusCode}) =>
    CloudWriteFailure(
      CloudWriteFailureType.remoteOutcomeUnknown,
      'Результат сохранения не удалось подтвердить. Проверьте файл вручную.',
      statusCode: statusCode,
      mayHaveSaved: true,
    );

Future<T> _awaitWithDeadline<T>(
  Future<T> operation,
  _CloudWriteDeadline deadline, {
  required Duration timeout,
  void Function()? abort,
}) async {
  final remaining = deadline.remaining;
  final bounded = remaining < timeout ? remaining : timeout;
  try {
    return await operation.timeout(bounded);
  } on CloudWriteFailure {
    rethrow;
  } on TimeoutException {
    abort?.call();
    throw const CloudWriteFailure(
      CloudWriteFailureType.timeout,
      'Mail.ru не ответил вовремя.',
    );
  }
}

int? _integerStatus(Object? value) => value is int ? value : null;
