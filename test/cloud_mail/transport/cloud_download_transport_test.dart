import 'dart:async';
import 'dart:io';

import 'package:easy_cloud/cloud_mail/transport/cloud_download_transport.dart';
import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:easy_cloud/features/download/domain/download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encodes UTF-8 while preserving only the cloud path safe set', () {
    expect(encodeCloudPath('Az09/_-. ü+?#'), 'Az09/_-.%20%C3%BC%2B%3F%23');
  });

  test(
    'uses the dispatcher and streams a strictly encoded download URL',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easy-cloud-download',
      );
      addTearDown(() => directory.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payload = <int>[1, 2, 3, 4, 5];
      final dispatcherTokens = <String>[];
      final downloadRequests = <HttpRequest>[];
      final serving = server.listen((request) async {
        if (request.uri.path == '/d') {
          dispatcherTokens.add(request.uri.queryParameters['token']!);
          request.response.write(
            'http://127.0.0.1:${server.port}/shard/ extra',
          );
        } else {
          downloadRequests.add(request);
          request.response.add(payload);
        }
        await request.response.close();
      });
      final auth = await _authRepository(_session(accessToken: 'access'));
      final transport = CloudDownloadTransport(
        authRepository: auth,
        dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      final progress = <({int bytes, int? total, bool resumed})>[];
      final part = File('${directory.path}/hash.part');

      try {
        final result = await transport.download(
          DownloadRequest(
            remotePath: '/Каталог/file name?.txt',
            partFile: part,
            expectedSize: payload.length,
          ),
          onProgress: (value) => progress.add((
            bytes: value.bytes,
            total: value.total,
            resumed: value.resumed,
          )),
        );

        expect(result.bytes, payload.length);
        expect(result.total, payload.length);
        expect(result.resumed, isFalse);
        expect(await part.readAsBytes(), payload);
        expect(dispatcherTokens, ['access']);
        expect(downloadRequests, hasLength(1));

        final download = downloadRequests.single;
        expect(download.uri.queryParameters, {
          'client_id': 'cloud-win',
          'token': 'access',
        });
        expect(
          download.uri.toString(),
          contains('/shard/%D0%9A%D0%B0%D1%82%D0%B0%D0%BB%D0%BE%D0%B3/'),
        );
        expect(download.uri.toString(), contains('file%20name%3F.txt'));
        expect(
          download.headers.value(HttpHeaders.userAgentHeader),
          'cloud-win',
        );
        expect(
          download.headers.value(HttpHeaders.acceptEncodingHeader),
          'identity',
        );
        expect(progress.last, (bytes: 5, total: 5, resumed: false));
      } finally {
        transport.close();
        auth.close();
        await serving.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'rejects untrusted and cleartext non-loopback shards before downloading',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easy-cloud-shard-policy',
      );
      addTearDown(() => directory.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final invalidShards = [
        'https://evil.example/shard',
        'http://192.0.2.1/shard',
      ];
      var dispatcherCalls = 0;
      var downloadCalls = 0;
      final serving = server.listen((request) async {
        if (request.uri.path == '/d') {
          request.response.write(invalidShards[dispatcherCalls++]);
        } else {
          downloadCalls++;
          request.response.add([1]);
        }
        await request.response.close();
      });
      final auth = await _authRepository(_session(accessToken: 'access'));
      final transport = CloudDownloadTransport(
        authRepository: auth,
        dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
      );

      try {
        await expectLater(
          transport.download(
            DownloadRequest(
              remotePath: '/file',
              partFile: File('${directory.path}/hash.part'),
            ),
          ),
          throwsA(
            isA<DownloadFailure>().having(
              (failure) => failure.type,
              'type',
              DownloadFailureType.invalidResponse,
            ),
          ),
        );
        expect(dispatcherCalls, 2);
        expect(downloadCalls, 0);
      } finally {
        transport.close();
        auth.close();
        await serving.cancel();
        await server.close(force: true);
      }
    },
  );

  test('resumes a part only after validating a matching 206 range', () async {
    final directory = await Directory.systemTemp.createTemp('easy-cloud-range');
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final part = File('${directory.path}/hash.part');
    await part.writeAsBytes([10, 11]);
    final ranges = <String?>[];
    final serving = server.listen((request) async {
      if (request.uri.path == '/d') {
        request.response.write('http://127.0.0.1:${server.port}/shard');
      } else {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-4/5',
        );
        request.response.add([12, 13, 14]);
      }
      await request.response.close();
    });
    final auth = await _authRepository(_session(accessToken: 'access'));
    final transport = CloudDownloadTransport(
      authRepository: auth,
      dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
    );

    try {
      final result = await transport.download(
        DownloadRequest(remotePath: '/file', partFile: part, expectedSize: 5),
      );

      expect(result.resumed, isTrue);
      expect(result.bytes, 5);
      expect(ranges, ['bytes=2-']);
      expect(await part.readAsBytes(), [10, 11, 12, 13, 14]);
    } finally {
      transport.close();
      auth.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test('restarts from zero when a server ignores Range', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easy-cloud-range-200',
    );
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final part = File('${directory.path}/hash.part');
    await part.writeAsBytes([99, 99]);
    final ranges = <String?>[];
    final serving = server.listen((request) async {
      if (request.uri.path == '/d') {
        request.response.write('http://127.0.0.1:${server.port}/shard');
      } else {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        request.response.add([1, 2, 3]);
      }
      await request.response.close();
    });
    final auth = await _authRepository(_session(accessToken: 'access'));
    final transport = CloudDownloadTransport(
      authRepository: auth,
      dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
    );

    try {
      final result = await transport.download(
        DownloadRequest(remotePath: '/file', partFile: part, expectedSize: 3),
      );

      expect(result.resumed, isFalse);
      expect(ranges, ['bytes=2-']);
      expect(await part.readAsBytes(), [1, 2, 3]);
    } finally {
      transport.close();
      auth.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test('truncates and retries from zero after a 416 response', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easy-cloud-range-416',
    );
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final part = File('${directory.path}/hash.part');
    await part.writeAsBytes([99, 99]);
    final ranges = <String?>[];
    var downloadCalls = 0;
    final serving = server.listen((request) async {
      if (request.uri.path == '/d') {
        request.response.write('http://127.0.0.1:${server.port}/shard');
      } else {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        downloadCalls++;
        if (downloadCalls == 1) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        } else {
          request.response.add([1, 2, 3]);
        }
      }
      await request.response.close();
    });
    final auth = await _authRepository(_session(accessToken: 'access'));
    final transport = CloudDownloadTransport(
      authRepository: auth,
      dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
    );

    try {
      final result = await transport.download(
        DownloadRequest(remotePath: '/file', partFile: part, expectedSize: 3),
      );

      expect(result.bytes, 3);
      expect(ranges, ['bytes=2-', null]);
      expect(await part.readAsBytes(), [1, 2, 3]);
    } finally {
      transport.close();
      auth.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test('rejects a 206 whose Content-Range starts at the wrong byte', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easy-cloud-range-invalid',
    );
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final part = File('${directory.path}/hash.part');
    await part.writeAsBytes([1, 2]);
    final serving = server.listen((request) async {
      if (request.uri.path == '/d') {
        request.response.write('http://127.0.0.1:${server.port}/shard');
      } else {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 1-2/3',
        );
        request.response.add([3, 4]);
      }
      await request.response.close();
    });
    final auth = await _authRepository(_session(accessToken: 'access'));
    final transport = CloudDownloadTransport(
      authRepository: auth,
      dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
    );

    try {
      await expectLater(
        transport.download(
          DownloadRequest(remotePath: '/file', partFile: part),
        ),
        throwsA(
          isA<DownloadFailure>().having(
            (failure) => failure.type,
            'type',
            DownloadFailureType.invalidResponse,
          ),
        ),
      );
      expect(await part.exists(), isFalse);
    } finally {
      transport.close();
      auth.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test('aborts the request and reports typed cancellation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easy-cloud-cancel',
    );
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final firstChunk = Completer<void>();
    final release = Completer<void>();
    final serving = server.listen((request) async {
      try {
        if (request.uri.path == '/d') {
          request.response.write('http://127.0.0.1:${server.port}/shard');
        } else {
          request.response.bufferOutput = false;
          request.response.add([1]);
          await request.response.flush();
          if (!firstChunk.isCompleted) firstChunk.complete();
          await release.future;
          request.response.add([2]);
        }
        await request.response.close();
      } catch (_) {
        if (!firstChunk.isCompleted) firstChunk.complete();
      }
    });
    final auth = await _authRepository(_session(accessToken: 'access'));
    final transport = CloudDownloadTransport(
      authRepository: auth,
      dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    final cancellation = DownloadCancellationToken();
    final part = File('${directory.path}/hash.part');

    try {
      final download = transport.download(
        DownloadRequest(remotePath: '/file', partFile: part),
        cancellation: cancellation,
      );
      await firstChunk.future;
      cancellation.cancel();
      await expectLater(
        download,
        throwsA(
          isA<DownloadFailure>().having(
            (failure) => failure.type,
            'type',
            DownloadFailureType.cancelled,
          ),
        ),
      );
      release.complete();
      expect(await part.exists(), isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      await cancellation.close();
      transport.close();
      auth.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test(
    'keeps a partial initial response and resumes it on the next download',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easy-cloud-cancel-resume',
      );
      addTearDown(() => directory.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstChunk = Completer<void>();
      final partWritten = Completer<void>();
      final release = Completer<void>();
      final ranges = <String?>[];
      var downloadCalls = 0;
      final serving = server.listen((request) async {
        try {
          if (request.uri.path == '/d') {
            request.response.write('http://127.0.0.1:${server.port}/shard');
          } else {
            downloadCalls++;
            ranges.add(request.headers.value(HttpHeaders.rangeHeader));
            if (downloadCalls == 1) {
              request.response.bufferOutput = false;
              request.response.add([1, 2]);
              await request.response.flush();
              if (!firstChunk.isCompleted) firstChunk.complete();
              await release.future;
            } else {
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes 2-3/4',
              );
              request.response.add([3, 4]);
            }
          }
          await request.response.close();
        } catch (_) {
          if (!firstChunk.isCompleted) firstChunk.complete();
        }
      });
      final auth = await _authRepository(_session(accessToken: 'access'));
      final transport = CloudDownloadTransport(
        authRepository: auth,
        dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      final cancellation = DownloadCancellationToken();
      final part = File('${directory.path}/hash.part');

      try {
        final interrupted = transport.download(
          DownloadRequest(remotePath: '/file', partFile: part, expectedSize: 4),
          cancellation: cancellation,
          onProgress: (progress) {
            if (progress.bytes == 2 && !partWritten.isCompleted) {
              partWritten.complete();
            }
          },
        );
        await firstChunk.future;
        await partWritten.future;
        cancellation.cancel();
        await expectLater(
          interrupted,
          throwsA(
            isA<DownloadFailure>().having(
              (failure) => failure.type,
              'type',
              DownloadFailureType.cancelled,
            ),
          ),
        );
        expect(await part.readAsBytes(), [1, 2]);
        release.complete();
        await cancellation.close();

        final result = await transport.download(
          DownloadRequest(remotePath: '/file', partFile: part, expectedSize: 4),
        );

        expect(result.bytes, 4);
        expect(result.resumed, isTrue);
        expect(ranges, [null, 'bytes=2-']);
        expect(await part.readAsBytes(), [1, 2, 3, 4]);
      } finally {
        if (!release.isCompleted) release.complete();
        if (!cancellation.isCancelled) await cancellation.close();
        transport.close();
        auth.close();
        await serving.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'refreshes once and re-resolves the shard after auth rejection',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easy-cloud-auth',
      );
      addTearDown(() => directory.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dispatcherTokens = <String>[];
      final downloadTokens = <String>[];
      final serving = server.listen((request) async {
        final token = request.uri.queryParameters['token'];
        if (request.uri.path == '/d') {
          dispatcherTokens.add(token!);
          request.response.write('http://127.0.0.1:${server.port}/shard');
        } else {
          downloadTokens.add(token!);
          request.response.statusCode = downloadTokens.length == 1
              ? HttpStatus.unauthorized
              : HttpStatus.ok;
          if (downloadTokens.length > 1) request.response.add([7, 8]);
        }
        await request.response.close();
      });
      final authApi = _RotatingAuthApi();
      final auth = AuthRepository(api: authApi, store: MemorySessionStore());
      await auth.login(email: 'test@mail.ru', password: 'password');
      final transport = CloudDownloadTransport(
        authRepository: auth,
        dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
      );

      try {
        final result = await transport.download(
          DownloadRequest(
            remotePath: '/file',
            partFile: File('${directory.path}/hash.part'),
            expectedSize: 2,
          ),
        );

        expect(result.bytes, 2);
        expect(authApi.refreshCalls, 1);
        expect(dispatcherTokens, ['old-access', 'new-access']);
        expect(downloadTokens, ['old-access', 'new-access']);
      } finally {
        transport.close();
        auth.close();
        await serving.cancel();
        await server.close(force: true);
      }
    },
  );

  test('re-resolves the shard once after a transient shard failure', () async {
    final directory = await Directory.systemTemp.createTemp('easy-cloud-retry');
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var dispatcherCalls = 0;
    var downloadCalls = 0;
    final serving = server.listen((request) async {
      if (request.uri.path == '/d') {
        dispatcherCalls++;
        request.response.write('http://127.0.0.1:${server.port}/shard');
      } else {
        downloadCalls++;
        request.response.statusCode = downloadCalls == 1
            ? HttpStatus.badGateway
            : HttpStatus.ok;
        if (downloadCalls > 1) request.response.add([4]);
      }
      await request.response.close();
    });
    final auth = await _authRepository(_session(accessToken: 'access'));
    final transport = CloudDownloadTransport(
      authRepository: auth,
      dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
    );

    try {
      final result = await transport.download(
        DownloadRequest(
          remotePath: '/file',
          partFile: File('${directory.path}/hash.part'),
          expectedSize: 1,
        ),
      );

      expect(result.bytes, 1);
      expect(dispatcherCalls, 2);
      expect(downloadCalls, 2);
    } finally {
      transport.close();
      auth.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test('bounds and retries a malformed shard response once', () async {
    final directory = await Directory.systemTemp.createTemp('easy-cloud-shard');
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var dispatcherCalls = 0;
    final serving = server.listen((request) async {
      dispatcherCalls++;
      request.response.write('not a shard URL');
      await request.response.close();
    });
    final auth = await _authRepository(_session(accessToken: 'access'));
    final transport = CloudDownloadTransport(
      authRepository: auth,
      dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
    );

    try {
      await expectLater(
        transport.download(
          DownloadRequest(
            remotePath: '/file',
            partFile: File('${directory.path}/hash.part'),
          ),
        ),
        throwsA(
          isA<DownloadFailure>().having(
            (failure) => failure.type,
            'type',
            DownloadFailureType.invalidResponse,
          ),
        ),
      );
      expect(dispatcherCalls, 2);
    } finally {
      transport.close();
      auth.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test('rejects an oversized shard response without buffering it', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easy-cloud-shard-limit',
    );
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var dispatcherCalls = 0;
    final serving = server.listen((request) async {
      dispatcherCalls++;
      request.response.write('x' * 32);
      await request.response.close();
    });
    final auth = await _authRepository(_session(accessToken: 'access'));
    final transport = CloudDownloadTransport(
      authRepository: auth,
      dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
      maxShardResponseBytes: 8,
    );

    try {
      await expectLater(
        transport.download(
          DownloadRequest(
            remotePath: '/file',
            partFile: File('${directory.path}/hash.part'),
          ),
        ),
        throwsA(
          isA<DownloadFailure>().having(
            (failure) => failure.type,
            'type',
            DownloadFailureType.invalidResponse,
          ),
        ),
      );
      expect(dispatcherCalls, 2);
    } finally {
      transport.close();
      auth.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test(
    'deletes the part when a chunked body exceeds expected size while streaming',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easy-cloud-download-limit',
      );
      addTearDown(() => directory.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final part = File('${directory.path}/hash.part');
      final serving = server.listen((request) async {
        try {
          if (request.uri.path == '/d') {
            request.response.write('http://127.0.0.1:${server.port}/shard');
          } else {
            request.response.bufferOutput = false;
            request.response.headers.chunkedTransferEncoding = true;
            request.response.add([1, 2]);
            await request.response.flush();
            request.response.add([3, 4]);
          }
          await request.response.close();
        } catch (_) {
          // The client aborts the response after detecting the oversized body.
        }
      });
      final auth = await _authRepository(_session(accessToken: 'access'));
      final transport = CloudDownloadTransport(
        authRepository: auth,
        dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
      );

      try {
        await expectLater(
          transport.download(
            DownloadRequest(
              remotePath: '/file',
              partFile: part,
              expectedSize: 3,
            ),
          ),
          throwsA(
            isA<DownloadFailure>().having(
              (failure) => failure.type,
              'type',
              DownloadFailureType.invalidResponse,
            ),
          ),
        );
        expect(await part.exists(), isFalse);
      } finally {
        transport.close();
        auth.close();
        await serving.cancel();
        await server.close(force: true);
      }
    },
  );

  test('keeps auth and shard retry budgets independent', () async {
    final directory = await Directory.systemTemp.createTemp(
      'easy-cloud-independent-retries',
    );
    addTearDown(() => directory.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dispatcherTokens = <String>[];
    final downloadTokens = <String>[];
    var dispatcherCalls = 0;
    var downloadCalls = 0;
    final serving = server.listen((request) async {
      final token = request.uri.queryParameters['token'];
      if (request.uri.path == '/d') {
        dispatcherCalls++;
        dispatcherTokens.add(token!);
        if (dispatcherCalls == 1) {
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          request.response.write('http://127.0.0.1:${server.port}/shard');
        }
      } else {
        downloadCalls++;
        downloadTokens.add(token!);
        if (downloadCalls == 1) {
          request.response.statusCode = HttpStatus.badGateway;
        } else {
          request.response.add([7, 8]);
        }
      }
      await request.response.close();
    });
    final authApi = _RotatingAuthApi();
    final auth = AuthRepository(api: authApi, store: MemorySessionStore());
    await auth.login(email: 'test@mail.ru', password: 'password');
    final transport = CloudDownloadTransport(
      authRepository: auth,
      dispatcherUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
    );

    try {
      final result = await transport.download(
        DownloadRequest(
          remotePath: '/file',
          partFile: File('${directory.path}/hash.part'),
          expectedSize: 2,
        ),
      );

      expect(result.bytes, 2);
      expect(authApi.refreshCalls, 1);
      expect(dispatcherCalls, 3);
      expect(downloadCalls, 2);
      expect(dispatcherTokens, ['old-access', 'new-access', 'new-access']);
      expect(downloadTokens, ['new-access', 'new-access']);
    } finally {
      transport.close();
      auth.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });
}

Future<AuthRepository> _authRepository(CloudSession session) async {
  final auth = AuthRepository(
    api: _StaticAuthApi(session),
    store: MemorySessionStore(),
  );
  await auth.login(email: session.email, password: 'password');
  return auth;
}

CloudSession _session({required String accessToken}) => CloudSession(
  email: 'test@mail.ru',
  accessToken: accessToken,
  refreshToken: 'refresh',
  csrfToken: 'csrf',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
);

final class _StaticAuthApi implements AuthApi {
  _StaticAuthApi(this.session);

  final CloudSession session;

  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => session;

  @override
  Future<CloudSession> refresh(CloudSession session) async => session;

  @override
  void close() {}
}

final class _RotatingAuthApi implements AuthApi {
  int refreshCalls = 0;

  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => _session(accessToken: 'old-access');

  @override
  Future<CloudSession> refresh(CloudSession session) async {
    refreshCalls++;
    return CloudSession(
      email: session.email,
      accessToken: 'new-access',
      refreshToken: 'new-refresh',
      csrfToken: 'new-csrf',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  void close() {}
}
