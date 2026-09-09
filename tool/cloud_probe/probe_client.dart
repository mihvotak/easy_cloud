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
  }) => _apiRequest(
    session,
    'GET',
    'folder',
    query: {
      'home': _cloudPath(path),
      'offset': '$offset',
      'limit': '$limit',
      'sort': '{"type":"name","order":"asc"}',
    },
  );

  Future<ProbeResponse> stat(OAuthSession session, String path) =>
      _apiRequest(session, 'GET', 'file', query: {'home': _cloudPath(path)});

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

  Future<void> upload(
    OAuthSession session,
    File source,
    String remotePath,
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

    final hashMatch = RegExp(
      r'^[0-9a-fA-F]{40}',
    ).firstMatch(response.text.trim());
    if (hashMatch == null) {
      throw ProbeException('Upload shard did not return a 40-character hash.');
    }
    final serverHash = hashMatch.group(0)!.toUpperCase();
    if (serverHash != localHash) {
      throw ProbeException('Upload hash differs from the local cloud hash.');
    }

    await _apiRequest(
      session,
      'POST',
      'file/add',
      form: {
        'api': '2',
        'conflict': 'strict',
        'home': _cloudPath(remotePath),
        'hash': serverHash,
        'size': '$size',
      },
    );
    final metadata = await _metadata(session, remotePath);
    if (metadata.size != null && metadata.size != size) {
      throw ProbeException('Remote size does not match after registration.');
    }
    if (metadata.hash != null && metadata.hash!.toUpperCase() != serverHash) {
      throw ProbeException('Remote hash does not match after registration.');
    }
    stdout.writeln('upload verified: $size bytes, hash $serverHash');
  }

  Future<RemoteMetadata> _metadata(OAuthSession session, String path) async {
    final response = await stat(session, path);
    final envelope = _jsonObject(response, operation: 'stat');
    final body = envelope['body'];
    if (body is! Map) {
      throw ProbeException('Stat response body is not an object.');
    }
    return RemoteMetadata(
      size: _asInt(body['size']),
      hash: body['hash'] as String?,
    );
  }

  Future<ProbeResponse> _apiRequest(
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
    _requireSuccess(response, endpoint);
    _requireApiEnvelopeSuccess(response, endpoint);
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

int? _asInt(Object? value) => switch (value) {
  int number => number,
  String text => int.tryParse(text),
  _ => null,
};

String _safeOAuthError(Object? value) {
  final error = value?.toString() ?? '';
  return RegExp(r'^[a-zA-Z0-9_./-]{1,64}$').hasMatch(error) ? error : 'unknown';
}
