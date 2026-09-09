import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_cloud/cloud_mail/probe/cloud_hash.dart';
import 'package:easy_cloud/cloud_mail/api/cloud_mail_api.dart';
import 'package:easy_cloud/cloud_mail/transport/cloud_transport.dart';
import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/download/data/cloud_download_repository.dart';
import 'package:easy_cloud/features/download/domain/download.dart';
import 'package:easy_cloud/local/cache/content_addressed_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('downloads, verifies, commits, and reports ordered phases', () async {
    final payload = utf8.encode('fresh download');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-download');
    addTearDown(() => root.delete(recursive: true));

    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final statTransport = _StatTransport([
      _file('/stale.txt', payload.length, hash),
    ]);
    final downloadTransport = _DownloadTransport(payload);
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: statTransport,
      downloadTransport: downloadTransport,
    );
    addTearDown(repository.close);

    final events = <DownloadProgress>[];
    final handle = repository.start(
      const CloudNode(
        path: '/stale.txt',
        name: 'stale.txt',
        type: CloudNodeType.file,
        size: 1,
        hash: '00112233445566778899AABBCCDDEEFF00112233',
      ),
    );
    final subscription = handle.progress.listen(events.add);
    final result = await handle.result;
    await subscription.cancel();

    expect(await result.readAsBytes(), payload);
    expect(events.map((event) => event.phase), [
      DownloadPhase.resolving,
      DownloadPhase.receiving,
      DownloadPhase.verifying,
      DownloadPhase.committed,
    ]);
    expect(events.last.cacheHit, isFalse);
    expect(events.last.bytes, payload.length);
    expect(downloadTransport.calls, 1);
    expect(downloadTransport.lastRequest?.expectedSize, payload.length);
    expect(downloadTransport.lastRequest?.remotePath, '/stale.txt');
    expect(result.path, isNot(endsWith('.part')));
  });

  test(
    'uses only a verified cache hit and does not invoke transport',
    () async {
      final payload = utf8.encode('cached file');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-download');
      addTearDown(() => root.delete(recursive: true));
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await object.parent.create(recursive: true);
      await object.writeAsBytes(payload);

      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final statTransport = _StatTransport([
        _file('/cached.txt', payload.length, hash),
      ]);
      final downloadTransport = _DownloadTransport(const []);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
      );
      addTearDown(repository.close);

      final events = <DownloadProgress>[];
      final handle = repository.start(_node('/cached.txt'));
      final subscription = handle.progress.listen(events.add);
      final result = await handle.result;
      await subscription.cancel();

      expect(result.path, object.path);
      expect(await result.readAsBytes(), payload);
      expect(downloadTransport.calls, 0);
      expect(events.map((event) => event.phase), [
        DownloadPhase.resolving,
        DownloadPhase.committed,
      ]);
      expect(events.last.cacheHit, isTrue);
    },
  );

  test('discards a corrupted object before replacing it', () async {
    final payload = utf8.encode('correct contents');
    final corrupted = utf8.encode('corrupt contents');
    expect(corrupted.length, payload.length);
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-download');
    addTearDown(() => root.delete(recursive: true));
    final cache = ContentAddressedFileCache(root: root, email: 'test@mail.ru');
    final object = await cache.objectFile(hash);
    await object.parent.create(recursive: true);
    await object.writeAsBytes(corrupted);

    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport([
        _file('/replace.txt', payload.length, hash),
      ]),
      downloadTransport: _DownloadTransport(payload),
    );
    addTearDown(repository.close);

    final result = await repository.start(_node('/replace.txt')).result;

    expect(await result.readAsBytes(), payload);
    expect(await object.readAsBytes(), payload);
  });

  test(
    'uses fresh stat size and hash instead of stale node metadata',
    () async {
      final payload = utf8.encode('new metadata');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-download');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final statTransport = _StatTransport([
        _file('/stale-name.bin', payload.length, hash),
      ]);
      final downloadTransport = _DownloadTransport(payload);
      final factoryEmails = <String>[];
      final repository = CloudDownloadRepository(
        api: CloudMailApi(statTransport),
        transport: downloadTransport,
        authRepository: auth,
        cacheFactory: (email) {
          factoryEmails.add(email);
          return ContentAddressedFileCache(root: root, email: email);
        },
      );
      addTearDown(repository.close);

      final result = await repository
          .start(
            const CloudNode(
              path: '/stale-name.bin',
              name: 'stale-name.bin',
              type: CloudNodeType.file,
              size: 999,
              hash: '00112233445566778899AABBCCDDEEFF00112233',
            ),
          )
          .result;

      expect(await result.readAsBytes(), payload);
      expect(statTransport.paths, ['/stale-name.bin']);
      expect(downloadTransport.lastRequest?.remotePath, '/stale-name.bin');
      expect(downloadTransport.lastRequest?.expectedSize, payload.length);
      expect(factoryEmails, ['test@mail.ru']);
    },
  );

  test(
    'rejects stat metadata for a different path before downloading',
    () async {
      final payload = utf8.encode('path mismatch');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-path');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final statTransport = _StatTransport([
        _file('/other.txt', payload.length, hash),
      ]);
      final downloadTransport = _DownloadTransport(payload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
      );
      addTearDown(repository.close);

      final handle = repository.start(_node('/requested.txt'));
      await expectLater(
        handle.result,
        throwsA(
          isA<DownloadFailure>().having(
            (failure) => failure.type,
            'type',
            DownloadFailureType.invalidResponse,
          ),
        ),
      );

      expect(statTransport.paths, ['/requested.txt']);
      expect(downloadTransport.calls, 0);
    },
  );

  test('hash mismatch is typed and leaves no final object', () async {
    final expected = utf8.encode('expected bytes');
    final actual = utf8.encode('actual bytes!!');
    expect(actual.length, expected.length);
    final hash = calculateCloudHash(expected);
    final root = await Directory.systemTemp.createTemp('easy-cloud-download');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final cache = ContentAddressedFileCache(root: root, email: 'test@mail.ru');
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport([_file('/bad.txt', expected.length, hash)]),
      downloadTransport: _DownloadTransport(actual),
    );
    addTearDown(repository.close);

    final handle = repository.start(_node('/bad.txt'));
    await expectLater(
      handle.result,
      throwsA(
        isA<DownloadIntegrityFailure>().having(
          (failure) => failure.type,
          'type',
          DownloadFailureType.integrity,
        ),
      ),
    );

    final paths = await cache.paths(hash);
    expect(await paths.objectFile.exists(), isFalse);
    expect(await paths.partFile.exists(), isFalse);
  });

  test('cancellation completes with typed failure', () async {
    final payload = utf8.encode('will not finish');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-download');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final downloadTransport = _DownloadTransport.pending();
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport([
        _file('/cancel.txt', payload.length, hash),
      ]),
      downloadTransport: downloadTransport,
    );
    addTearDown(repository.close);

    final handle = repository.start(_node('/cancel.txt'));
    await downloadTransport.started!.future;
    handle.cancel();

    await expectLater(handle.result, throwsA(isA<DownloadCancelled>()));
    expect(downloadTransport.calls, 1);
  });

  test('close owns only the download transport', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-download');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final statTransport = _StatTransport([
      _file('/close.txt', 0, calculateCloudHash(const [])),
    ]);
    final downloadTransport = _DownloadTransport(const []);
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: statTransport,
      downloadTransport: downloadTransport,
    );

    repository.close();

    expect(downloadTransport.closed, isTrue);
    expect(statTransport.closed, isFalse);
    repository.close();
  });

  test('close cancels active operations and rejects new starts', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-close');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final statTransport = _StatTransport([
      _file('/close.txt', 0, calculateCloudHash(const [])),
    ]);
    final downloadTransport = _DownloadTransport.pending();
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: statTransport,
      downloadTransport: downloadTransport,
    );
    addTearDown(repository.close);

    final handle = repository.start(_node('/close.txt'));
    await downloadTransport.started!.future;
    repository.close();

    await expectLater(handle.result, throwsA(isA<DownloadCancelled>()));
    expect(downloadTransport.closed, isTrue);
    expect(
      () => repository.start(_node('/close.txt')),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'serializes same-hash writes and lets the second start use the cache',
    () async {
      final payload = utf8.encode('shared download');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-shared');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      final statTransport = _StatTransport([
        _file('/shared.txt', payload.length, hash),
        _file('/shared.txt', payload.length, hash),
      ]);
      final downloadTransport = _DownloadTransport(
        payload,
        started: writeStarted,
        releaseWrite: releaseWrite,
      );
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
      );
      addTearDown(repository.close);

      final first = repository.start(_node('/shared.txt'));
      await writeStarted.future;
      final second = repository.start(_node('/shared.txt'));
      final secondEvents = <DownloadProgress>[];
      final subscription = second.progress.listen(secondEvents.add);
      releaseWrite.complete();

      final files = await Future.wait([first.result, second.result]);
      await subscription.cancel();

      expect(files[0].path, files[1].path);
      expect(downloadTransport.calls, 1);
      expect(downloadTransport.maxConcurrentWrites, 1);
      expect(secondEvents.last.phase, DownloadPhase.committed);
      expect(secondEvents.last.cacheHit, isTrue);
    },
  );
}

CloudDownloadRepository _repository({
  required Directory root,
  required AuthRepository auth,
  required _StatTransport statTransport,
  required _DownloadTransport downloadTransport,
}) => CloudDownloadRepository(
  api: CloudMailApi(statTransport),
  transport: downloadTransport,
  authRepository: auth,
  cacheRoot: root,
);

CloudNode _node(String path) => CloudNode(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.file,
);

CloudNode _file(String path, int size, String hash) => CloudNode(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.file,
  size: size,
  hash: hash,
);

Future<AuthRepository> _authenticatedRepository() async {
  final store = MemorySessionStore()..session = _session();
  final repository = AuthRepository(api: _AuthApi(), store: store);
  await repository.restore();
  return repository;
}

CloudSession _session() => CloudSession(
  email: 'test@mail.ru',
  accessToken: 'access',
  refreshToken: 'refresh',
  csrfToken: 'csrf',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
);

final class _AuthApi implements AuthApi {
  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => _session();

  @override
  Future<CloudSession> refresh(CloudSession session) async => session;

  @override
  void close() {}
}

final class _StatTransport implements CloudTransport {
  _StatTransport(this.nodes);

  final List<CloudNode> nodes;
  final paths = <String>[];
  int calls = 0;
  bool closed = false;

  @override
  Future<CloudResponse> get(
    String endpoint, {
    Map<String, String> query = const {},
    bool includeCsrfQuery = false,
  }) async {
    expect(endpoint, 'file');
    expect(includeCsrfQuery, isFalse);
    paths.add(query['home']!);
    final node = nodes[calls++];
    return CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(
        jsonEncode({
          'status': 200,
          'body': {
            'home': node.path,
            'name': node.name,
            'type': 'file',
            'size': node.size,
            'hash': node.hash,
          },
        }),
      ),
    );
  }

  @override
  void close() => closed = true;
}

final class _DownloadTransport implements DownloadTransport {
  _DownloadTransport(
    this.payload, {
    this.started,
    Completer<void>? releaseWrite,
  }) : _releaseWrite = releaseWrite,
       _pending = false;

  _DownloadTransport.pending()
    : payload = const [],
      started = Completer<void>(),
      _releaseWrite = null,
      _pending = true;

  final List<int> payload;
  final Completer<void>? started;
  final Completer<void>? _releaseWrite;
  final bool _pending;
  int calls = 0;
  int activeWrites = 0;
  int maxConcurrentWrites = 0;
  bool closed = false;
  DownloadRequest? lastRequest;

  @override
  Future<DownloadResult> download(
    DownloadRequest request, {
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellation,
  }) async {
    calls++;
    lastRequest = request;
    if (_pending) {
      started!.complete();
      await cancellation!.cancellations.first;
      throw const DownloadCancelled();
    }

    started?.complete();
    await _releaseWrite?.future;
    activeWrites++;
    if (activeWrites > maxConcurrentWrites) {
      maxConcurrentWrites = activeWrites;
    }
    try {
      await request.partFile.writeAsBytes(payload, flush: true);
    } finally {
      activeWrites--;
    }
    onProgress?.call(
      DownloadProgress(
        bytes: payload.length,
        total: request.expectedSize,
        resumed: false,
      ),
    );
    return DownloadResult(
      partFile: request.partFile,
      bytes: payload.length,
      total: request.expectedSize,
      resumed: false,
    );
  }

  @override
  void close() => closed = true;
}
