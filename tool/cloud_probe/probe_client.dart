import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_cloud/cloud_mail/probe/cloud_hash.dart';
import 'package:easy_cloud/cloud_mail/probe/redactor.dart';
import 'package:easy_cloud/cloud_mail/probe/response_shape.dart';

import 'probe_options.dart';

final class ProbeException implements Exception {
  ProbeException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum FileConflict {
  strict,
  rewrite,
  rename;

  String get wireValue => name;
}

enum FileAddError {
  exists,
  contentNotFound,
  overQuota,
  readOnly,
  unauthorized,
  invalidRequest,
  apiFailure,
  httpFailure,
  invalidResponse,
}

final class CloudFileIdentity {
  const CloudFileIdentity({required this.hash, required this.size});

  final String hash;
  final int size;
}

final class UploadShardResult {
  const UploadShardResult({required this.hash, required this.size});

  final String hash;
  final int? size;
}

final class FileAddResult {
  const FileAddResult._({
    required this.statusCode,
    required this.returnedPath,
    required this.error,
  });

  const FileAddResult.success({required int statusCode, String? returnedPath})
    : this._(statusCode: statusCode, returnedPath: returnedPath, error: null);

  const FileAddResult.failure({
    required int statusCode,
    required FileAddError error,
  }) : this._(statusCode: statusCode, returnedPath: null, error: error);

  final int statusCode;
  final String? returnedPath;
  final FileAddError? error;

  bool get succeeded => error == null;
}

final class OAuthSession {
  OAuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  final String accessToken;
  final String? refreshToken;
  final int? expiresIn;
  String? csrfToken;
}

final class ProbeResponse {
  ProbeResponse({
    required this.statusCode,
    required this.bytes,
    required this.headers,
  });

  final int statusCode;
  final List<int> bytes;
  final HttpHeaders headers;

  String get text => utf8.decode(bytes);

  Object? get json => jsonDecode(text);
}

final class RemoteMetadata {
  RemoteMetadata({required this.size, required this.hash});

  final int? size;
  final String? hash;
}

final class CloudProbeClient {
  CloudProbeClient(this.options) : _httpClient = HttpClient();

  final ProbeOptions options;
  final HttpClient _httpClient;

  void close() => _httpClient.close(force: true);

  Future<OAuthSession> login(String email, String password) async {
    final response = await _send(
      'POST',
      options.oauthUrl,
      form: {
        'client_id': options.clientId,
        'grant_type': 'password',
        'username': email,
        'password': password,
      },
    );
    final body = _jsonObject(response, operation: 'login');
    final token = body['access_token'];
    if (token is! String || token.isEmpty) {
      final error = _safeOAuthError(body['error']);
      throw ProbeException(
        'Login did not return an access token '
        '(error: $error, error_code: ${body['error_code'] ?? 'unknown'}).',
      );
    }
    return OAuthSession(
      accessToken: token,
      refreshToken: body['refresh_token'] as String?,
      expiresIn: _asInt(body['expires_in']),
    );
  }

  Future<OAuthSession> refresh(OAuthSession session) async {
    final refreshToken = session.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw ProbeException('Login response did not include a refresh token.');
    }
    final response = await _send(
      'POST',
      options.oauthUrl,
      form: {
        'client_id': options.clientId,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
    );
    final body = _jsonObject(response, operation: 'refresh');
    final token = body['access_token'];
    if (token is! String || token.isEmpty) {
      final error = _safeOAuthError(body['error']);
      throw ProbeException(
        'Refresh did not return an access token '
        '(error: $error, error_code: ${body['error_code'] ?? 'unknown'}).',
      );
    }
    return OAuthSession(
      accessToken: token,
      refreshToken: body['refresh_token'] as String? ?? refreshToken,
      expiresIn: _asInt(body['expires_in']),
    );
  }

  Future<String> acquireCsrf(OAuthSession session) async {
    final response = await _apiRequest(
      session,
      'GET',
      'tokens/csrf',
      includeCsrf: false,
    );
    final envelope = _jsonObject(response, operation: 'csrf');
    final body = envelope['body'];
    final token = body is Map ? body['token'] : null;
    if (token is! String || token.isEmpty) {
      throw ProbeException('CSRF response did not include body.token.');
    }
    session.csrfToken = token;
    return token;
  }

  Future<void> probeDispatcher(OAuthSession session) async {
    await _apiRequest(session, 'POST', 'dispatcher/', form: const {});
    final download = await resolveShard(session, 'd');
    final upload = await resolveShard(session, 'u');
    stdout.writeln('download shard: ${_originOnly(download)}');
    stdout.writeln('upload shard: ${_originOnly(upload)}');
  }

  Future<Uri> resolveShard(OAuthSession session, String kind) async {
    final uri = _withQuery(options.dispatcherUrl.resolve(kind), {
      'token': session.accessToken,
    });
    final response = await _send('GET', uri);
    _requireSuccess(response, 'dispatcher /$kind');
    final firstField = response.text.trim().split(RegExp(r'\s+')).firstOrNull;
    final shard = firstField == null ? null : Uri.tryParse(firstField);
    if (shard == null || !shard.hasScheme || shard.host.isEmpty) {
      throw ProbeException('Dispatcher /$kind returned an invalid shard URL.');
    }
    return shard;
  }

  Future<ProbeResponse> listFolder(
    OAuthSession session,
    String path, {
    int offset = 0,
    int limit = 100,
    String sortType = 'name',
    String sortOrder = 'asc',
  }) => _apiRequest(
    session,
    'GET',
    'folder',
    query: {
      'home': _cloudPath(path),
      'offset': '$offset',
      'limit': '$limit',
      'sort': jsonEncode({'type': sortType, 'order': sortOrder}),
    },
  );

  Future<void> probeSortMatrix(
    OAuthSession session,
    String path, {
    int limit = 100,
  }) async {
    for (final sortType in const ['name', 'size', 'mtime']) {
      for (final sortOrder in const ['asc', 'desc']) {
        stdout.writeln('\n=== sort $sortType/$sortOrder ===');
        final response = await listFolder(
          session,
          path,
          limit: limit,
          sortType: sortType,
          sortOrder: sortOrder,
        );
        final envelope = _jsonObject(response, operation: 'sort matrix');
        final body = envelope['body'];
        if (body is! Map) {
          throw ProbeException('Folder response body is not an object.');
        }
        final sort = body['sort'];
        final list = body['list'];
        if (sort is! Map || list is! List) {
          throw ProbeException(
            'Folder response omitted body.sort or body.list.',
          );
        }
        final appliedType = sort['type'];
        final appliedOrder = sort['order'];
        if (appliedType != sortType || appliedOrder != sortOrder) {
          throw ProbeException(
            'Server applied ${_safeSortValue(appliedType)}/${_safeSortValue(appliedOrder)} '
            'instead of $sortType/$sortOrder.',
          );
        }
        stdout.writeln(
          'sort confirmed: $appliedType/$appliedOrder, page items=${list.length}',
        );
      }
    }
  }

  Future<ProbeResponse> stat(OAuthSession session, String path) =>
      _apiRequest(session, 'GET', 'file', query: {'home': _cloudPath(path)});

  Future<RemoteMetadata> readMetadata(OAuthSession session, String path) =>
      _metadata(session, path);

  Future<ProbeResponse> search(
    OAuthSession session,
    String query, {
    String path = '/',
    int limit = 100,
  }) => _apiRequest(
    session,
    'GET',
    'folder/find',
    query: {
      'q': query,
      'path': _cloudPath(path),
      'limit': '$limit',
      if (session.csrfToken != null) 'token': session.csrfToken!,
    },
  );

  Future<ProbeResponse> history(OAuthSession session, String path) =>
      _apiRequest(
        session,
        'GET',
        'file/history',
        query: {'home': _cloudPath(path)},
      );

  Future<ProbeResponse> removeFile(OAuthSession session, String path) =>
      _apiRequest(
        session,
        'POST',
        'file/remove',
        form: {'home': _cloudPath(path), 'conflict': ''},
      );

  Future<void> probeRange(
    OAuthSession session,
    String remotePath, {
    int start = 0,
    int end = 31,
  }) async {
    if (start < 0 || end < start) {
      throw ProbeException('Range must satisfy 0 <= start <= end.');
    }
    final shard = await resolveShard(session, 'd');
    final uri = _downloadUri(shard, session, remotePath);
    final response = await _send(
      'GET',
      uri,
      headers: {'Range': 'bytes=$start-$end', 'User-Agent': options.clientId},
    );
    stdout.writeln(
      'Accept-Ranges: ${response.headers.value('accept-ranges') ?? 'absent'}',
    );
    stdout.writeln(
      'Content-Range: ${response.headers.value('content-range') ?? 'absent'}',
    );
    if (response.statusCode != HttpStatus.partialContent) {
      stdout.writeln('Range is not confirmed: expected HTTP 206.');
    }
  }

  Future<void> download(
    OAuthSession session,
    String remotePath,
    File destination, {
    bool overwrite = false,
  }) async {
    if (await destination.exists() && !overwrite) {
      throw ProbeException(
        'Destination already exists. Use --overwrite to replace it.',
      );
    }

    final metadata = await _metadata(session, remotePath);
    final shard = await resolveShard(session, 'd');
    final uri = _downloadUri(shard, session, remotePath);
    final temporary = File('${destination.path}.part');
    if (await temporary.exists()) await temporary.delete();

    try {
      final request = await _openRequest(
        'GET',
        uri,
        headers: {'User-Agent': options.clientId},
      );
      final response = await request.close();
      _logResponseHeaders(response.statusCode, response.headers);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = await _readLimited(response);
        stdout.writeln(
          'RESPONSE SHAPE ${responseShape(error, contentType: response.headers.contentType?.mimeType)}',
        );
        throw ProbeException(
          'Download failed with HTTP ${response.statusCode}.',
        );
      }

      final sink = temporary.openWrite();
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
      }
      await sink.flush();
      await sink.close();
      stdout.writeln('RESPONSE SHAPE binary($received bytes)');

      if (metadata.size != null && received != metadata.size) {
        throw ProbeException(
          'Size mismatch: expected ${metadata.size}, received $received.',
        );
      }
      final localHash = await calculateCloudFileHash(temporary);
      if (metadata.hash != null &&
          localHash.toUpperCase() != metadata.hash!.toUpperCase()) {
        throw ProbeException('Cloud hash mismatch after download.');
      }
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
      stdout.writeln('download verified: $received bytes, hash $localHash');
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<CloudFileIdentity> uploadContent(
    OAuthSession session,
    File source,
  ) async {
    if (!await source.exists()) {
      throw ProbeException('Local file does not exist: ${source.path}');
    }
    final size = await source.length();
    final localHash = await calculateCloudFileHash(source);
    final shard = await resolveShard(session, 'u');
    final uploadUri = _withQuery(shard, {
      'client_id': options.clientId,
      'token': session.accessToken,
    });
    final request = await _openRequest(
      'PUT',
      uploadUri,
      headers: {HttpHeaders.contentTypeHeader: 'application/octet-stream'},
    );
    request.contentLength = size;
    await request.addStream(source.openRead());
    final rawResponse = await request.close();
    final response = ProbeResponse(
      statusCode: rawResponse.statusCode,
      bytes: await _readLimited(rawResponse),
      headers: rawResponse.headers,
    );
    _logResponse(response);
    _requireSuccess(response, 'upload content');

    final uploadResult = parseUploadShardResponse(
      response.text,
      expectedSize: size,
    );
    if (uploadResult.hash != localHash) {
      throw ProbeException('Upload hash differs from the local cloud hash.');
    }

    return CloudFileIdentity(hash: uploadResult.hash, size: size);
  }

  Future<void> upload(
    OAuthSession session,
    File source,
    String remotePath,
  ) async {
    final identity = await uploadContent(session, source);

    await _apiRequest(
      session,
      'POST',
      'file/add',
      form: {
        'api': '2',
        'conflict': 'strict',
        'home': _cloudPath(remotePath),
        'hash': identity.hash,
        'size': '${identity.size}',
      },
    );
    final metadata = await _metadata(session, remotePath);
    if (metadata.size != null && metadata.size != identity.size) {
      throw ProbeException('Remote size does not match after registration.');
    }
    if (metadata.hash != null &&
        metadata.hash!.toUpperCase() != identity.hash) {
      throw ProbeException('Remote hash does not match after registration.');
    }
    stdout.writeln(
      'upload verified: ${identity.size} bytes, hash ${identity.hash}',
    );
  }

  Future<FileAddResult> registerByIdentity(
    OAuthSession session,
    CloudFileIdentity identity,
    String remotePath, {
    required FileConflict conflict,
  }) async {
    _validateIdentity(identity);
    final path = _validatedFilePath(remotePath);
    final response = await _apiRequestRaw(
      session,
      'POST',
      'file/add',
      form: {
        'api': '2',
        'conflict': conflict.wireValue,
        'home': path,
        'hash': identity.hash.toUpperCase(),
        'size': '${identity.size}',
      },
    );
    return _parseFileAddResult(response, conflict: conflict);
  }

  FileAddResult _parseFileAddResult(
    ProbeResponse response, {
    required FileConflict conflict,
  }) {
    final error = _classifyFileAddError(response);
    if (error != null) {
      return FileAddResult.failure(
        statusCode: response.statusCode,
        error: error,
      );
    }

    final envelope = _tryJsonObject(response);
    final returnedPath = envelope == null
        ? null
        : _extractReturnedPath(envelope['body']);
    if (conflict == FileConflict.rename && returnedPath == null) {
      return FileAddResult.failure(
        statusCode: response.statusCode,
        error: FileAddError.invalidResponse,
      );
    }
    return FileAddResult.success(
      statusCode: response.statusCode,
      returnedPath: returnedPath,
    );
  }

  FileAddError? _classifyFileAddError(ProbeResponse response) {
    final envelope = _tryJsonObject(response);
    final apiStatus = envelope == null ? null : _asInt(envelope['status']);
    final code = envelope == null
        ? _plainFileAddErrorCode(response)
        : _fileAddErrorCode(envelope);
    final mappedCode = _mapFileAddError(code);
    if (mappedCode != null) return mappedCode;

    if (response.statusCode == HttpStatus.unauthorized ||
        response.statusCode == HttpStatus.forbidden ||
        apiStatus == HttpStatus.unauthorized ||
        apiStatus == HttpStatus.forbidden) {
      return FileAddError.unauthorized;
    }
    if (apiStatus != null && apiStatus >= 400) {
      return FileAddError.apiFailure;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return FileAddError.httpFailure;
    }
    if (envelope != null &&
        (envelope['error'] != null || _hasNestedFileAddError(envelope))) {
      return FileAddError.apiFailure;
    }
    return null;
  }

  String? _plainFileAddErrorCode(ProbeResponse response) {
    try {
      final text = response.text.trim();
      return RegExp(r'^[a-zA-Z_/]+$').hasMatch(text) ? text : null;
    } on FormatException {
      return null;
    }
  }

  String? _fileAddErrorCode(Map<String, Object?> envelope) {
    final topLevelError = envelope['error'];
    if (topLevelError is String) return topLevelError;

    final body = envelope['body'];
    if (body is String) return body;
    if (body is! Map) return null;

    final directError = body['error'];
    if (directError is String) return directError;
    for (final key in const ['home', 'weblink', 'invite_email']) {
      final value = body[key];
      if (value is Map && value['error'] is String) {
        return value['error'] as String;
      }
    }
    return null;
  }

  bool _hasNestedFileAddError(Map<String, Object?> envelope) {
    final body = envelope['body'];
    if (body is! Map) return false;
    if (body['error'] is String) return true;
    return const ['home', 'weblink', 'invite_email'].any((key) {
      final value = body[key];
      return value is Map && value['error'] is String;
    });
  }

  FileAddError? _mapFileAddError(String? value) {
    final normalized = value?.trim().toLowerCase();
    return switch (normalized) {
      'exists' => FileAddError.exists,
      'not_exists' || 'content_not_found' => FileAddError.contentNotFound,
      'overquota' || 'quota_exceeded' => FileAddError.overQuota,
      'readonly' || 'read_only' => FileAddError.readOnly,
      'required' || 'invalid' => FileAddError.invalidRequest,
      'token' ||
      'user' ||
      'not/authorized' ||
      'not_authorized' => FileAddError.unauthorized,
      null => null,
      _ => null,
    };
  }

  Map<String, Object?>? _tryJsonObject(ProbeResponse response) {
    try {
      final value = response.json;
      if (value is Map) return value.cast<String, Object?>();
    } on FormatException {
      // The response shape is already logged without exposing its body.
    }
    return null;
  }

  String? _extractReturnedPath(Object? body) {
    Object? candidate = body;
    if (body is Map) {
      candidate = body['home'] ?? body['path'];
    }
    if (candidate is! String) return null;
    return _safeFilePath(candidate);
  }

  String? _safeFilePath(String value) {
    final path = value.trim();
    if (path.length < 2 ||
        path.length > 4096 ||
        !path.startsWith('/') ||
        path.startsWith('//') ||
        path.endsWith('/') ||
        path.contains('\\')) {
      return null;
    }
    if (path.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
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

  String _validatedFilePath(String value) {
    final path = _safeFilePath(_cloudPath(value));
    if (path == null) {
      throw ProbeException(
        'Remote file path must be a non-root absolute path.',
      );
    }
    return path;
  }

  void _validateIdentity(CloudFileIdentity identity) {
    if (identity.size < 0) {
      throw ProbeException('File identity size cannot be negative.');
    }
    if (!RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(identity.hash)) {
      throw ProbeException(
        'File identity hash must be a 40-character hex value.',
      );
    }
  }

  Future<RemoteMetadata> _metadata(OAuthSession session, String path) async {
    final response = await stat(session, path);
    final envelope = _jsonObject(response, operation: 'stat');
    final body = envelope['body'];
    if (body is! Map) {
      throw ProbeException('Stat response body is not an object.');
    }
    final hash = body['hash'];
    if (hash != null && hash is! String) {
      throw ProbeException('Stat response hash has an invalid shape.');
    }
    return RemoteMetadata(size: _asInt(body['size']), hash: hash as String?);
  }

  Future<ProbeResponse> _apiRequest(
    OAuthSession session,
    String method,
    String endpoint, {
    Map<String, String> query = const {},
    Map<String, String>? form,
    bool includeCsrf = true,
  }) async {
    final response = await _apiRequestRaw(
      session,
      method,
      endpoint,
      query: query,
      form: form,
      includeCsrf: includeCsrf,
    );
    _requireSuccess(response, endpoint);
    _requireApiEnvelopeSuccess(response, endpoint);
    return response;
  }

  Future<ProbeResponse> _apiRequestRaw(
    OAuthSession session,
    String method,
    String endpoint, {
    Map<String, String> query = const {},
    Map<String, String>? form,
    bool includeCsrf = true,
  }) async {
    final uri = _withQuery(options.apiUrl.resolve(endpoint), {
      ...query,
      'access_token': session.accessToken,
    });
    final csrf = session.csrfToken;
    final response = await _send(
      method,
      uri,
      headers: {if (includeCsrf && csrf != null) 'X-CSRF-Token': csrf},
      form: form,
    );
    return response;
  }

  Future<ProbeResponse> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Map<String, String>? form,
  }) async {
    final request = await _openRequest(
      method,
      uri,
      headers: headers,
      form: form,
    );
    final rawResponse = await request.close();
    final response = ProbeResponse(
      statusCode: rawResponse.statusCode,
      bytes: await _readLimited(rawResponse),
      headers: rawResponse.headers,
    );
    _logResponse(response);
    return response;
  }

  Future<HttpClientRequest> _openRequest(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Map<String, String>? form,
  }) async {
    stdout.writeln('METHOD $method');
    stdout.writeln('URL ${redactUri(uri)}');
    stdout.writeln('QUERY ${redactFields(uri.queryParameters)}');
    stdout.writeln('HEADERS ${redactFields(headers)}');
    if (form != null) stdout.writeln('BODY ${redactFields(form)}');

    final request = await _httpClient.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (form != null) {
      final encoded = Uri(queryParameters: form).query;
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(encoded);
    }
    return request;
  }

  void _logResponse(ProbeResponse response) {
    _logResponseHeaders(response.statusCode, response.headers);
    stdout.writeln(
      'RESPONSE SHAPE ${responseShape(response.bytes, contentType: response.headers.contentType?.mimeType)}',
    );
  }

  void _logResponseHeaders(int statusCode, HttpHeaders headers) {
    stdout.writeln('HTTP STATUS $statusCode');
    stdout.writeln('CONTENT-TYPE ${headers.contentType?.mimeType ?? 'absent'}');
  }

  Map<String, Object?> _jsonObject(
    ProbeResponse response, {
    required String operation,
  }) {
    _requireSuccess(response, operation);
    try {
      final value = response.json;
      if (value is Map) return value.cast<String, Object?>();
    } on FormatException {
      // A shape-only error below avoids printing a potentially sensitive body.
    }
    throw ProbeException('$operation did not return a JSON object.');
  }

  void _requireSuccess(ProbeResponse response, String operation) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProbeException(
        '$operation failed with HTTP ${response.statusCode}.',
      );
    }
  }

  void _requireApiEnvelopeSuccess(ProbeResponse response, String operation) {
    Object? decoded;
    try {
      decoded = response.json;
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;

    final status = _asInt(decoded['status']);
    final error = decoded['error']?.toString().toUpperCase();
    final body = decoded['body']?.toString().toLowerCase();
    if ((status != null && status >= 400) ||
        error == 'NOT/AUTHORIZED' ||
        body == 'token' ||
        body == 'user') {
      throw ProbeException(
        '$operation returned an API error (status: ${status ?? 'unknown'}).',
      );
    }
  }

  Uri _downloadUri(Uri shard, OAuthSession session, String remotePath) {
    final path = remotePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final base = shard.toString().replaceFirst(RegExp(r'/+$'), '');
    return _withQuery(Uri.parse('$base/$path'), {
      'client_id': options.clientId,
      'token': session.accessToken,
    });
  }
}

Future<List<int>> _readLimited(HttpClientResponse response) async {
  const limit = 4 * 1024 * 1024;
  final output = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in response) {
    length += chunk.length;
    if (length > limit) {
      throw ProbeException('Response exceeds the probe limit of $limit bytes.');
    }
    output.add(chunk);
  }
  return output.takeBytes();
}

Uri _withQuery(Uri uri, Map<String, String> values) =>
    uri.replace(queryParameters: {...uri.queryParameters, ...values});

String _cloudPath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed == '/') return '/';
  return '/${trimmed.replaceFirst(RegExp(r'^/+'), '')}';
}

String _originOnly(Uri uri) => '${uri.scheme}://${uri.authority}';

UploadShardResult parseUploadShardResponse(
  String response, {
  required int expectedSize,
}) {
  if (expectedSize < 0) {
    throw ProbeException('Expected upload size cannot be negative.');
  }

  final match = RegExp(
    r'^([0-9a-fA-F]{40})(?:;([0-9]+))?$',
  ).firstMatch(response.trim());
  if (match == null) {
    throw ProbeException(
      'Upload shard response must be HASH or HASH;DECIMAL_SIZE.',
    );
  }

  final reportedSizeText = match.group(2);
  int? reportedSize;
  if (reportedSizeText != null) {
    reportedSize = int.tryParse(reportedSizeText);
    if (reportedSize == null) {
      throw ProbeException('Upload shard returned an invalid decimal size.');
    }
    if (reportedSize != expectedSize) {
      throw ProbeException(
        'Upload shard size differs from the local content size.',
      );
    }
  }

  return UploadShardResult(
    hash: match.group(1)!.toUpperCase(),
    size: reportedSize,
  );
}

int? _asInt(Object? value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};

String _safeOAuthError(Object? value) {
  final error = value?.toString() ?? '';
  return RegExp(r'^[a-zA-Z0-9_./-]{1,64}$').hasMatch(error) ? error : 'unknown';
}

String _safeSortValue(Object? value) {
  final text = value?.toString() ?? '';
  return RegExp(r'^[a-z]+$').hasMatch(text) ? text : 'unknown';
}
