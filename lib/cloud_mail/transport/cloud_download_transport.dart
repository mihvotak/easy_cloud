import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../features/auth/application/auth_repository.dart';
import '../../features/auth/domain/auth_failure.dart';
import '../../features/auth/domain/cloud_session.dart';
import '../../features/download/domain/download.dart';

const _defaultDispatcherUrl = 'https://dispatcher.cloud.mail.ru/';
const _defaultClientId = 'cloud-win';
const _defaultShardResponseLimit = 64 * 1024;

/// Streams a Cloud Mail.ru binary response into a caller-owned `.part` file.
///
/// This transport never verifies content hashes or renames the part. Those
/// operations belong to the download orchestration and file cache layers.
final class CloudDownloadTransport implements DownloadTransport {
  CloudDownloadTransport({
    required AuthRepository authRepository,
    HttpClient? httpClient,
    Uri? dispatcherUrl,
    this.clientId = _defaultClientId,
    this.maxShardResponseBytes = _defaultShardResponseLimit,
    this.requestTimeout = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 30),
  }) : _authRepository = authRepository,
       _httpClient = httpClient ?? HttpClient(),
       _dispatcherUrl = dispatcherUrl ?? Uri.parse(_defaultDispatcherUrl) {
    if (clientId.isEmpty) throw ArgumentError.value(clientId, 'clientId');
    if (maxShardResponseBytes <= 0) {
      throw ArgumentError.value(maxShardResponseBytes, 'maxShardResponseBytes');
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
    if (readTimeout <= Duration.zero) {
      throw ArgumentError.value(readTimeout, 'readTimeout');
    }
  }

  final AuthRepository _authRepository;
  final HttpClient _httpClient;
  final Uri _dispatcherUrl;

  final String clientId;
  final int maxShardResponseBytes;
  final Duration requestTimeout;
  final Duration readTimeout;

  @override
  Future<DownloadResult> download(
    DownloadRequest request, {
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellation,
  }) async {
    if (!_isValidRemotePath(request.remotePath)) {
      throw ArgumentError.value(request.remotePath, 'remotePath');
    }
    cancellation?.throwIfCancelled();

    var session = await _freshSession();
    cancellation?.throwIfCancelled();
    var authRetryUsed = false;
    var shardRetryUsed = false;

    while (true) {
      cancellation?.throwIfCancelled();
      try {
        final shard = await _resolveShard(session, cancellation);
        return await _downloadFromShard(
          request,
          session,
          shard,
          onProgress: onProgress,
          cancellation: cancellation,
        );
      } on _RetryDownload catch (retry) {
        cancellation?.throwIfCancelled();
        if (retry.reason == _RetryReason.auth) {
          if (authRetryUsed) {
            await _logoutIfCurrent(session);
            throw retry.toFailure();
          }
          authRetryUsed = true;
          session = await _refreshAfterRejection(session);
        } else {
          if (shardRetryUsed) throw retry.toFailure();
          shardRetryUsed = true;
        }
      }
    }
  }

  Future<CloudSession> _freshSession() async {
    try {
      return await _authRepository.requireFreshSession();
    } on AuthFailure catch (failure) {
      throw _fromAuthFailure(failure);
    }
  }

  Future<CloudSession> _refreshAfterRejection(CloudSession session) async {
    try {
      return await _authRepository.refreshAfterRejection(session.accessToken);
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
      // The in-memory session is already cleared by AuthRepository.
    }
  }

  Future<Uri> _resolveShard(
    CloudSession session,
    DownloadCancellationToken? cancellation,
  ) async {
    final uri = _dispatcherUrl
        .resolve('d')
        .replace(queryParameters: {'token': session.accessToken});

    return _withResponse<Uri>(
      uri,
      cancellation: cancellation,
      downloadRequest: false,
      operation: (response) async {
        final status = response.statusCode;
        if (_isAuthRejected(status)) {
          await _discardResponse(response);
          throw const _RetryDownload(_RetryReason.auth);
        }
        if (_isRedirect(status)) {
          await _discardResponse(response);
          throw const _RetryDownload(_RetryReason.redirect);
        }
        if (status < 200 || status >= 300) {
          await _discardResponse(response);
          throw _RetryDownload(
            _RetryReason.shard,
            statusCode: status,
            message: 'Диспетчер вернул HTTP $status.',
          );
        }

        try {
          final body = await _readShardBody(response, cancellation);
          final firstField = body.trim().split(RegExp(r'\s+')).first;
          final shard = Uri.tryParse(firstField);
          if (shard == null || !_isValidShard(shard)) {
            throw const FormatException('Invalid shard URL.');
          }
          return shard;
        } on DownloadFailure catch (failure) {
          if (failure.type == DownloadFailureType.invalidResponse) {
            throw _RetryDownload(_RetryReason.shard, message: failure.message);
          }
          rethrow;
        } on FormatException {
          throw const _RetryDownload(
            _RetryReason.shard,
            message: 'Диспетчер вернул неизвестный адрес загрузки.',
          );
        }
      },
    );
  }

  Future<DownloadResult> _downloadFromShard(
    DownloadRequest request,
    CloudSession session,
    Uri shard, {
    required DownloadProgressCallback? onProgress,
    required DownloadCancellationToken? cancellation,
  }) async {
    try {
      try {
        await request.partFile.parent.create(recursive: true);
      } on FileSystemException catch (error) {
        throw DownloadFailure(
          DownloadFailureType.disk,
          'Не удалось подготовить файл загрузки.',
          cause: error,
        );
      }

      var offset = await _partLength(request.partFile);
      if (request.expectedSize != null && offset > request.expectedSize!) {
        await _truncatePart(request.partFile);
        offset = 0;
      }

      final response = await _requestDownload(
        request,
        session,
        shard,
        offset,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      if (!response.resetRange) return response.result!;

      await _truncatePart(request.partFile);
      final restarted = await _requestDownload(
        request,
        session,
        shard,
        0,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      if (restarted.resetRange) {
        throw const DownloadFailure(
          DownloadFailureType.invalidResponse,
          'Сервер повторно отклонил загрузку с начала.',
        );
      }
      return restarted.result!;
    } on DownloadFailure catch (failure) {
      if (failure.type == DownloadFailureType.invalidResponse ||
          failure.type == DownloadFailureType.disk) {
        await _deletePartQuietly(request.partFile);
      }
      rethrow;
    }
  }

  Future<_DownloadResponse> _requestDownload(
    DownloadRequest request,
    CloudSession session,
    Uri shard,
    int offset, {
    required DownloadProgressCallback? onProgress,
    required DownloadCancellationToken? cancellation,
  }) async {
    final uri = buildCloudDownloadUri(
      shard,
      request.remotePath,
      clientId: clientId,
      accessToken: session.accessToken,
    );
    final headers = <String, String>{if (offset > 0) 'Range': 'bytes=$offset-'};

    return _withResponse<_DownloadResponse>(
      uri,
      cancellation: cancellation,
      downloadRequest: true,
      headers: headers,
      operation: (response) async {
        final status = response.statusCode;
        if (_isAuthRejected(status)) {
          await _discardResponse(response);
          throw const _RetryDownload(_RetryReason.auth);
        }
        if (_isRedirect(status)) {
          await _discardResponse(response);
          throw const _RetryDownload(_RetryReason.redirect);
        }
        if (status == HttpStatus.requestedRangeNotSatisfiable) {
          await _discardResponse(response);
          if (offset > 0) return const _DownloadResponse.reset();
          throw DownloadFailure(
            DownloadFailureType.service,
            'Сервер не принял диапазон загрузки.',
            statusCode: status,
          );
        }
        if (status == HttpStatus.ok) {
          late final int? total;
          try {
            total = _totalForFullResponse(response, request.expectedSize);
          } on DownloadFailure {
            await _discardResponse(response);
            rethrow;
          }
          return _DownloadResponse.completed(
            await _streamResponse(
              response,
              request.partFile,
              offset: 0,
              resumed: false,
              total: total,
              expectedSize: request.expectedSize,
              onProgress: onProgress,
              cancellation: cancellation,
            ),
          );
        }
        if (status == HttpStatus.partialContent) {
          if (offset == 0) {
            await _discardResponse(response);
            throw const DownloadFailure(
              DownloadFailureType.invalidResponse,
              'Сервер вернул 206 без запрошенного диапазона.',
            );
          }
          late final _ContentRange range;
          try {
            range = _validateContentRange(
              response,
              offset,
              request.expectedSize,
            );
          } on DownloadFailure {
            await _discardResponse(response);
            rethrow;
          }
          return _DownloadResponse.completed(
            await _streamResponse(
              response,
              request.partFile,
              offset: offset,
              resumed: true,
              total: range.total,
              expectedResponseBytes: range.length,
              expectedSize: request.expectedSize,
              onProgress: onProgress,
              cancellation: cancellation,
            ),
          );
        }

        await _discardResponse(response);
        if (status < 200 || status >= 300) {
          if (status >= 500 || status == HttpStatus.tooManyRequests) {
            throw _RetryDownload(
              _RetryReason.shard,
              statusCode: status,
              message: 'Шард загрузки вернул HTTP $status.',
            );
          }
          throw _failureForStatus(status, 'Загрузка');
        }
        throw DownloadFailure(
          DownloadFailureType.invalidResponse,
          'Сервер вернул неподдерживаемый ответ HTTP $status.',
          statusCode: status,
        );
      },
    );
  }

  int? _totalForFullResponse(HttpClientResponse response, int? expectedSize) {
    final advertised = response.contentLength >= 0
        ? response.contentLength
        : null;
    if (expectedSize != null &&
        advertised != null &&
        advertised != expectedSize) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Размер ответа не совпадает с ожидаемым размером.',
      );
    }
    return expectedSize ?? advertised;
  }

  _ContentRange _validateContentRange(
    HttpClientResponse response,
    int expectedStart,
    int? expectedSize,
  ) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = value == null
        ? null
        : RegExp(
            r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
            caseSensitive: false,
          ).firstMatch(value.trim());
    if (match == null) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Ответ 206 не содержит корректный Content-Range.',
      );
    }

    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final totalValue = match.group(3)!;
    final total = totalValue == '*' ? null : int.tryParse(totalValue);
    final contentLength = response.contentLength;
    if (start == null ||
        end == null ||
        (totalValue != '*' && total == null) ||
        start != expectedStart ||
        end < start ||
        (total != null && total <= end)) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Ответ 206 содержит неверный диапазон.',
      );
    }
    if (contentLength >= 0 && contentLength != end - start + 1) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Длина ответа 206 не совпадает с Content-Range.',
      );
    }
    if (expectedSize != null && total != null && total != expectedSize) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Content-Range не совпадает с ожидаемым размером.',
      );
    }
    if (expectedSize != null && expectedSize < end + 1) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Content-Range выходит за ожидаемый размер.',
      );
    }
    return _ContentRange(total: total ?? expectedSize, length: end - start + 1);
  }

  Future<DownloadResult> _streamResponse(
    HttpClientResponse response,
    File partFile, {
    required int offset,
    required bool resumed,
    required int? total,
    int? expectedResponseBytes,
    required int? expectedSize,
    required DownloadProgressCallback? onProgress,
    required DownloadCancellationToken? cancellation,
  }) async {
    IOSink? sink;
    StreamSubscription<List<int>>? responseSubscription;
    StreamSubscription<void>? cancellationSubscription;
    var received = 0;
    try {
      sink = partFile.openWrite(
        mode: resumed ? FileMode.append : FileMode.write,
      );
      final responseDone = Completer<void>();
      responseSubscription = response
          .timeout(readTimeout)
          .listen(
            (chunk) {
              if (responseDone.isCompleted) return;
              try {
                cancellation?.throwIfCancelled();
                if (chunk.isEmpty) return;
                final nextReceived = received + chunk.length;
                final responseLimit =
                    expectedResponseBytes ??
                    (expectedSize == null ? null : expectedSize - offset);
                if (responseLimit != null && nextReceived > responseLimit) {
                  throw const DownloadFailure(
                    DownloadFailureType.invalidResponse,
                    'Ответ превышает ожидаемый размер файла.',
                  );
                }
                sink!.add(chunk);
                received = nextReceived;
                onProgress?.call(
                  DownloadProgress(
                    bytes: offset + received,
                    total: total,
                    resumed: resumed,
                  ),
                );
              } catch (error, stackTrace) {
                if (!responseDone.isCompleted) {
                  responseDone.completeError(error, stackTrace);
                }
                responseSubscription?.cancel();
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!responseDone.isCompleted) {
                responseDone.completeError(error, stackTrace);
              }
            },
            onDone: () {
              if (!responseDone.isCompleted) responseDone.complete();
            },
          );
      if (cancellation != null) {
        cancellationSubscription = cancellation.cancellations.listen((_) {
          responseSubscription?.cancel();
          if (!responseDone.isCompleted) {
            responseDone.completeError(const DownloadCancelled());
          }
        });
        cancellation.throwIfCancelled();
      }
      await responseDone.future;
      await cancellationSubscription?.cancel();
      cancellationSubscription = null;
      await responseSubscription.cancel();
      responseSubscription = null;
      cancellation?.throwIfCancelled();
      await sink.flush();
      await sink.close();
      sink = null;

      final bytes = offset + received;
      if ((expectedResponseBytes != null &&
              received != expectedResponseBytes) ||
          (total != null && bytes != total) ||
          (expectedSize != null && bytes != expectedSize)) {
        throw const DownloadFailure(
          DownloadFailureType.invalidResponse,
          'Размер загруженного файла не совпадает с ожидаемым.',
        );
      }
      if (received == 0) {
        onProgress?.call(
          DownloadProgress(bytes: bytes, total: total, resumed: resumed),
        );
      }
      return DownloadResult(
        partFile: partFile,
        bytes: bytes,
        total: total,
        resumed: resumed,
      );
    } catch (error) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // Preserve the original failure and its useful cancellation type.
        }
      }
      await cancellationSubscription?.cancel();
      await responseSubscription?.cancel();
      final failure = cancellation?.isCancelled == true
          ? const DownloadCancelled()
          : error is DownloadFailure
          ? error
          : _mapStreamError(error);
      final bytes = offset + received;
      if (!_shouldPreservePart(failure, bytes, expectedSize)) {
        await _deletePartQuietly(partFile);
      }
      throw failure;
    }
  }

  Future<T> _withResponse<T>(
    Uri uri, {
    required DownloadCancellationToken? cancellation,
    required bool downloadRequest,
    required Future<T> Function(HttpClientResponse response) operation,
    Map<String, String> headers = const {},
  }) async {
    HttpClientRequest? request;
    StreamSubscription<void>? cancellationSubscription;
    try {
      cancellation?.throwIfCancelled();
      request = await _httpClient.getUrl(uri).timeout(requestTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, clientId);
      if (downloadRequest) {
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      }
      headers.forEach(request.headers.set);

      if (cancellation != null) {
        cancellationSubscription = cancellation.cancellations.listen((_) {
          try {
            request?.abort();
          } catch (_) {
            // The request may already be closed.
          }
        });
        cancellation.throwIfCancelled();
      }

      final response = await request.close().timeout(requestTimeout);
      return await operation(response);
    } on _RetryDownload {
      _abortQuietly(request);
      rethrow;
    } on DownloadFailure {
      _abortQuietly(request);
      rethrow;
    } catch (error) {
      _abortQuietly(request);
      if (cancellation?.isCancelled == true) {
        throw const DownloadCancelled();
      }
      throw _mapTransportError(error);
    } finally {
      await cancellationSubscription?.cancel();
    }
  }

  Future<String> _readShardBody(
    HttpClientResponse response,
    DownloadCancellationToken? cancellation,
  ) async {
    if (response.contentLength > maxShardResponseBytes) {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Ответ диспетчера слишком большой.',
      );
    }

    final bytes = BytesBuilder(copy: false);
    var length = 0;
    StreamSubscription<List<int>>? responseSubscription;
    StreamSubscription<void>? cancellationSubscription;
    final responseDone = Completer<void>();
    try {
      responseSubscription = response
          .timeout(readTimeout)
          .listen(
            (chunk) {
              if (responseDone.isCompleted) return;
              try {
                cancellation?.throwIfCancelled();
                length += chunk.length;
                if (length > maxShardResponseBytes) {
                  throw const DownloadFailure(
                    DownloadFailureType.invalidResponse,
                    'Ответ диспетчера слишком большой.',
                  );
                }
                bytes.add(chunk);
              } catch (error, stackTrace) {
                if (!responseDone.isCompleted) {
                  responseDone.completeError(error, stackTrace);
                }
                responseSubscription?.cancel();
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!responseDone.isCompleted) {
                responseDone.completeError(error, stackTrace);
              }
            },
            onDone: () {
              if (!responseDone.isCompleted) responseDone.complete();
            },
          );
      if (cancellation != null) {
        cancellationSubscription = cancellation.cancellations.listen((_) {
          responseSubscription?.cancel();
          if (!responseDone.isCompleted) {
            responseDone.completeError(const DownloadCancelled());
          }
        });
        cancellation.throwIfCancelled();
      }
      await responseDone.future;
      await cancellationSubscription?.cancel();
      cancellationSubscription = null;
      await responseSubscription.cancel();
      responseSubscription = null;
      cancellation?.throwIfCancelled();
      return utf8.decode(bytes.takeBytes());
    } on DownloadFailure {
      rethrow;
    } on FormatException {
      throw const DownloadFailure(
        DownloadFailureType.invalidResponse,
        'Ответ диспетчера содержит невалидный UTF-8.',
      );
    } finally {
      await cancellationSubscription?.cancel();
      await responseSubscription?.cancel();
    }
  }

  Future<void> _discardResponse(HttpClientResponse response) async {
    var length = 0;
    try {
      await for (final chunk in response.timeout(readTimeout)) {
        length += chunk.length;
        if (length > maxShardResponseBytes) break;
      }
    } catch (_) {
      // The status code is more useful than an optional error body here.
    }
  }

  Future<int> _partLength(File partFile) async {
    if (!await partFile.exists()) return 0;
    try {
      return await partFile.length();
    } on FileSystemException catch (error) {
      throw DownloadFailure(
        DownloadFailureType.disk,
        'Не удалось прочитать временный файл загрузки.',
        cause: error,
      );
    }
  }

  Future<void> _truncatePart(File partFile) async {
    try {
      await partFile.writeAsBytes(const [], flush: true);
    } on FileSystemException catch (error) {
      throw DownloadFailure(
        DownloadFailureType.disk,
        'Не удалось очистить временный файл загрузки.',
        cause: error,
      );
    }
  }

  Future<void> _deletePartQuietly(File partFile) async {
    try {
      if (await partFile.exists()) await partFile.delete();
    } on FileSystemException {
      // A cleanup failure must not replace the network or cancellation error.
    }
  }

  bool _shouldPreservePart(
    DownloadFailure failure,
    int bytes,
    int? expectedSize,
  ) {
    if (expectedSize == null || bytes <= 0 || bytes >= expectedSize) {
      return false;
    }
    return failure.type == DownloadFailureType.network ||
        failure.type == DownloadFailureType.timeout ||
        failure.type == DownloadFailureType.cancelled;
  }

  void _abortQuietly(HttpClientRequest? request) {
    try {
      request?.abort();
    } catch (_) {
      // The request may already be closed.
    }
  }

  @override
  void close() => _httpClient.close(force: true);
}

String encodeCloudPath(String path) {
  final bytes = utf8.encode(path);
  final result = StringBuffer();
  for (final byte in bytes) {
    if (_isUnreservedCloudPathByte(byte)) {
      result.writeCharCode(byte);
    } else {
      result
        ..write('%')
        ..write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
  }
  return result.toString();
}

Uri buildCloudDownloadUri(
  Uri shard,
  String remotePath, {
  String clientId = _defaultClientId,
  required String accessToken,
}) {
  if (!_isValidRemotePath(remotePath)) {
    throw ArgumentError.value(remotePath, 'remotePath');
  }
  final base = shard
      .replace(queryParameters: const {}, fragment: '')
      .toString()
      .replaceFirst(RegExp(r'[?#]+$'), '')
      .replaceFirst(RegExp(r'/+$'), '');
  final encodedPath = encodeCloudPath(
    remotePath,
  ).replaceFirst(RegExp(r'^/+'), '');
  final path = encodedPath.isEmpty ? '$base/' : '$base/$encodedPath';
  return Uri.parse(
    path,
  ).replace(queryParameters: {'client_id': clientId, 'token': accessToken});
}

bool _isValidRemotePath(String path) {
  if (!path.startsWith('/') || path.trim() != path || path.length < 2) {
    return false;
  }
  return !path.split('/').any((segment) => segment == '.' || segment == '..');
}

bool _isUnreservedCloudPathByte(int byte) =>
    (byte >= 0x41 && byte <= 0x5a) ||
    (byte >= 0x61 && byte <= 0x7a) ||
    (byte >= 0x30 && byte <= 0x39) ||
    byte == 0x2f || // slash
    byte == 0x5f || // underscore
    byte == 0x2d || // hyphen
    byte == 0x2e; // dot

bool _isValidShard(Uri shard) {
  final scheme = shard.scheme.toLowerCase();
  final host = shard.host.toLowerCase();
  final trustedHost =
      host == 'cloud.mail.ru' ||
      host.endsWith('.cloud.mail.ru') ||
      host == 'datacloudmail.ru' ||
      host.endsWith('.datacloudmail.ru');
  final loopback = host == 'localhost' || host == '127.0.0.1' || host == '::1';
  return shard.userInfo.isEmpty &&
      ((scheme == 'https' && trustedHost) ||
          ((scheme == 'http' || scheme == 'https') && loopback));
}

bool _isAuthRejected(int statusCode) =>
    statusCode == HttpStatus.unauthorized || statusCode == HttpStatus.forbidden;

bool _isRedirect(int statusCode) => statusCode >= 300 && statusCode < 400;

DownloadFailure _failureForStatus(int statusCode, String operation) {
  final type = switch (statusCode) {
    HttpStatus.notFound => DownloadFailureType.notFound,
    HttpStatus.forbidden => DownloadFailureType.permissionDenied,
    _ => DownloadFailureType.service,
  };
  return DownloadFailure(
    type,
    type == DownloadFailureType.notFound
        ? 'Файл не найден.'
        : '$operation завершилась с HTTP $statusCode.',
    statusCode: statusCode,
  );
}

DownloadFailure _fromAuthFailure(AuthFailure failure) =>
    DownloadFailure(switch (failure.type) {
      AuthFailureType.network => DownloadFailureType.network,
      AuthFailureType.authRequired ||
      AuthFailureType.invalidCredentials => DownloadFailureType.authRequired,
      AuthFailureType.invalidResponse => DownloadFailureType.invalidResponse,
      AuthFailureType.service ||
      AuthFailureType.secureStorage => DownloadFailureType.service,
    }, failure.message);

DownloadFailure _mapTransportError(Object error) => switch (error) {
  DownloadFailure failure => failure,
  TimeoutException() => const DownloadFailure(
    DownloadFailureType.timeout,
    'Mail.ru не ответил вовремя.',
  ),
  SocketException() || HandshakeException() => const DownloadFailure(
    DownloadFailureType.network,
    'Нет соединения с Mail.ru.',
  ),
  HttpException() => const DownloadFailure(
    DownloadFailureType.service,
    'Ошибка протокола Mail.ru.',
  ),
  _ => DownloadFailure(
    DownloadFailureType.service,
    'Не удалось выполнить загрузку.',
    cause: error,
  ),
};

DownloadFailure _mapStreamError(Object error) => switch (error) {
  DownloadFailure failure => failure,
  FileSystemException() => DownloadFailure(
    DownloadFailureType.disk,
    'Не удалось записать временный файл загрузки.',
    cause: error,
  ),
  TimeoutException() => const DownloadFailure(
    DownloadFailureType.timeout,
    'Загрузка не отвечает вовремя.',
  ),
  SocketException() || HandshakeException() => const DownloadFailure(
    DownloadFailureType.network,
    'Соединение с Mail.ru было прервано.',
  ),
  HttpException() => const DownloadFailure(
    DownloadFailureType.service,
    'Ошибка протокола Mail.ru.',
  ),
  _ => DownloadFailure(
    DownloadFailureType.service,
    'Не удалось записать загрузку.',
    cause: error,
  ),
};

enum _RetryReason { auth, redirect, shard }

final class _RetryDownload implements Exception {
  const _RetryDownload(this.reason, {this.statusCode, this.message});

  final _RetryReason reason;
  final int? statusCode;
  final String? message;

  DownloadFailure toFailure() {
    if (reason == _RetryReason.auth) {
      return DownloadFailure(
        DownloadFailureType.authRequired,
        'Сессия загрузки истекла. Войдите снова.',
        statusCode: statusCode,
      );
    }
    if (reason == _RetryReason.redirect) {
      return DownloadFailure(
        DownloadFailureType.service,
        message ?? 'Сервер перенаправил загрузку.',
        statusCode: statusCode,
      );
    }
    if (statusCode != null) {
      return _failureForStatus(statusCode!, message ?? 'Диспетчер загрузки');
    }
    if (message != null) {
      return DownloadFailure(
        DownloadFailureType.invalidResponse,
        message!,
        statusCode: statusCode,
      );
    }
    return _failureForStatus(statusCode ?? 500, 'Диспетчер загрузки');
  }
}

final class _DownloadResponse {
  const _DownloadResponse.completed(this.result) : resetRange = false;

  const _DownloadResponse.reset() : result = null, resetRange = true;

  final DownloadResult? result;
  final bool resetRange;
}

final class _ContentRange {
  const _ContentRange({required this.total, required this.length});

  final int? total;
  final int length;
}
