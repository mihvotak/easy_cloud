import 'dart:convert';
import 'dart:io';

import 'package:easy_cloud/cloud_mail/api/cloud_mail_api.dart';
import 'package:easy_cloud/cloud_mail/probe/cloud_hash.dart';
import 'package:easy_cloud/cloud_mail/transport/cloud_transport.dart';
import 'package:easy_cloud/cloud_mail/transport/cloud_write_transport.dart';
import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/auth_failure.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/download/domain/download_cancellation.dart';
import 'package:easy_cloud/features/editor/data/editor_save_repository.dart';
import 'package:easy_cloud/features/editor/domain/editor_save.dart';
import 'package:easy_cloud/features/offline/application/offline_file_index.dart';
import 'package:easy_cloud/local/cache/cloud_cache_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'checks the baseline, verifies post-stat, and keeps a transient object',
    () async {
      final bytes = utf8.encode('editor content');
      final hash = calculateCloudHash(bytes);
      final root = await Directory.systemTemp.createTemp('easy-cloud-editor');
      addTearDown(() => root.delete(recursive: true));

      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final node = _file('/docs/note.txt', hash, bytes.length);
      final stats = _StatTransport([node, node]);
      final writer = _RecordingWriteTransport();
      final transient = _MemoryTransientObjectIndex();
      final coordinator = CloudCacheCoordinator();
      addTearDown(coordinator.close);
      final repository = EditorSaveRepository(
        api: CloudMailApi(stats),
        authRepository: auth,
        writeTransport: writer,
        offlineFileIndex: _MemoryOfflineFileIndex(),
        transientObjectIndex: transient,
        cacheRoot: root,
        coordinator: coordinator,
      );
      addTearDown(repository.close);
      final progress = <EditorSaveProgress>[];

      final result = await repository.save(
        EditorSaveBaseline(path: node.path, hash: hash, size: bytes.length),
        bytes,
        onProgress: progress.add,
      );

      expect(result.path, node.path);
      expect(result.hash, hash);
      expect(result.size, bytes.length);
      expect(result.ownershipPolicy, EditorOwnershipPolicy.onlineOnly);
      expect(result.partialSuccess, isNull);
      expect(writer.conflicts, [CloudWriteConflictMode.rewrite]);
      expect(await writer.lastSource!.readAsBytes(), bytes);
      expect(transient.records, hasLength(1));
      expect(transient.records.values.single.hash, hash);
      expect(stats.paths, [node.path, node.path]);
      expect(progress.map((event) => event.phase), [
        EditorSavePhase.checkingConflict,
        EditorSavePhase.hashing,
        EditorSavePhase.preparingCache,
        EditorSavePhase.uploading,
        EditorSavePhase.verifyingRemote,
        EditorSavePhase.committingOwnership,
        EditorSavePhase.completed,
      ]);
    },
  );

  test('does not upload when the unchanged baseline has a conflict', () async {
    final bytes = utf8.encode('editor content');
    final baselineHash = calculateCloudHash(bytes);
    final remoteHash = calculateCloudHash(const [9, 8, 7]);
    final root = await Directory.systemTemp.createTemp('easy-cloud-editor');
    addTearDown(() => root.delete(recursive: true));

    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final node = _file('/docs/note.txt', remoteHash, 3);
    final writer = _RecordingWriteTransport();
    final coordinator = CloudCacheCoordinator();
    addTearDown(coordinator.close);
    final repository = EditorSaveRepository(
      api: CloudMailApi(_StatTransport([node])),
      authRepository: auth,
      writeTransport: writer,
      offlineFileIndex: _MemoryOfflineFileIndex(),
      cacheRoot: root,
      coordinator: coordinator,
    );
    addTearDown(repository.close);

    await expectLater(
      repository.save(
        EditorSaveBaseline(
          path: node.path,
          hash: baselineHash,
          size: bytes.length,
        ),
        bytes,
      ),
      throwsA(
        isA<EditorSaveFailure>().having(
          (failure) => failure.type,
          'type',
          EditorSaveFailureType.conflict,
        ),
      ),
    );
    expect(writer.conflicts, isEmpty);
  });

  test(
    'maps overwrite to rewrite and copy to a server-selected sibling',
    () async {
      final bytes = utf8.encode('editor content');
      final hash = calculateCloudHash(bytes);
      final node = _file('/docs/note.txt', hash, bytes.length);
      final copy = _file('/docs/note (1).txt', hash, bytes.length);
      final root = await Directory.systemTemp.createTemp('easy-cloud-editor');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);

      final overwriteWriter = _RecordingWriteTransport();
      final overwriteTransient = _MemoryTransientObjectIndex();
      final overwriteCoordinator = CloudCacheCoordinator();
      addTearDown(overwriteCoordinator.close);
      final overwriteRepository = EditorSaveRepository(
        api: CloudMailApi(_StatTransport([node, node])),
        authRepository: auth,
        writeTransport: overwriteWriter,
        offlineFileIndex: _MemoryOfflineFileIndex(),
        transientObjectIndex: overwriteTransient,
        cacheRoot: root,
        coordinator: overwriteCoordinator,
      );
      addTearDown(overwriteRepository.close);
      await overwriteRepository.save(
        EditorSaveBaseline(path: node.path, hash: hash, size: bytes.length),
        bytes,
        choice: EditorSaveChoice.overwrite,
      );
      expect(overwriteWriter.conflicts, [CloudWriteConflictMode.rewrite]);

      final copyWriter = _RecordingWriteTransport(returnedPath: copy.path);
      final copyTransient = _MemoryTransientObjectIndex();
      final copyCoordinator = CloudCacheCoordinator();
      addTearDown(copyCoordinator.close);
      final copyRepository = EditorSaveRepository(
        api: CloudMailApi(_StatTransport([node, copy])),
        authRepository: auth,
        writeTransport: copyWriter,
        offlineFileIndex: _MemoryOfflineFileIndex(),
        transientObjectIndex: copyTransient,
        cacheRoot: root,
        coordinator: copyCoordinator,
      );
      addTearDown(copyRepository.close);
      final result = await copyRepository.save(
        EditorSaveBaseline(path: node.path, hash: hash, size: bytes.length),
        bytes,
        choice: EditorSaveChoice.copy,
      );
      expect(copyWriter.conflicts, [CloudWriteConflictMode.rename]);
      expect(result.path, copy.path);
    },
  );

  test(
    'reports an unknown remote outcome after post-registration verification',
    () async {
      final bytes = utf8.encode('editor content');
      final hash = calculateCloudHash(bytes);
      final otherHash = calculateCloudHash(const [4, 5, 6]);
      final baselineNode = _file('/docs/note.txt', hash, bytes.length);
      final changedNode = _file('/docs/note.txt', otherHash, 3);
      final root = await Directory.systemTemp.createTemp('easy-cloud-editor');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final coordinator = CloudCacheCoordinator();
      addTearDown(coordinator.close);
      final repository = EditorSaveRepository(
        api: CloudMailApi(_StatTransport([baselineNode, changedNode])),
        authRepository: auth,
        writeTransport: _RecordingWriteTransport(),
        offlineFileIndex: _MemoryOfflineFileIndex(),
        transientObjectIndex: _MemoryTransientObjectIndex(),
        cacheRoot: root,
        coordinator: coordinator,
      );
      addTearDown(repository.close);

      await expectLater(
        repository.save(
          EditorSaveBaseline(
            path: baselineNode.path,
            hash: hash,
            size: bytes.length,
          ),
          bytes,
        ),
        throwsA(
          isA<EditorSaveFailure>()
              .having(
                (failure) => failure.type,
                'type',
                EditorSaveFailureType.remoteOutcomeUnknown,
              )
              .having((failure) => failure.mayHaveSaved, 'mayHaveSaved', isTrue)
              .having((failure) => failure.canRetry, 'canRetry', isFalse),
        ),
      );
    },
  );

  test(
    'keeps the remote-outcome failure safe when registration is uncertain',
    () async {
      final bytes = utf8.encode('editor content');
      final hash = calculateCloudHash(bytes);
      final node = _file('/docs/note.txt', hash, bytes.length);
      final root = await Directory.systemTemp.createTemp('easy-cloud-editor');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final coordinator = CloudCacheCoordinator();
      addTearDown(coordinator.close);
      final repository = EditorSaveRepository(
        api: CloudMailApi(_StatTransport([node])),
        authRepository: auth,
        writeTransport: _RecordingWriteTransport(
          failure: CloudWriteFailure(
            CloudWriteFailureType.remoteOutcomeUnknown,
            'Результат сохранения не удалось подтвердить.',
            mayHaveSaved: true,
          ),
        ),
        offlineFileIndex: _MemoryOfflineFileIndex(),
        transientObjectIndex: _MemoryTransientObjectIndex(),
        cacheRoot: root,
        coordinator: coordinator,
      );
      addTearDown(repository.close);

      await expectLater(
        repository.save(
          EditorSaveBaseline(path: node.path, hash: hash, size: bytes.length),
          bytes,
        ),
        throwsA(
          isA<EditorSaveFailure>()
              .having(
                (failure) => failure.type,
                'type',
                EditorSaveFailureType.remoteOutcomeUnknown,
              )
              .having(
                (failure) => failure.message,
                'message',
                isNot(contains(hash)),
              )
              .having((failure) => failure.canRetry, 'canRetry', isFalse),
        ),
      );
    },
  );

  test(
    'returns partial success when verified remote ownership cannot be retained locally',
    () async {
      final bytes = utf8.encode('editor content');
      final hash = calculateCloudHash(bytes);
      final node = _file('/docs/note.txt', hash, bytes.length);
      final root = await Directory.systemTemp.createTemp('easy-cloud-editor');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final transient = _MemoryTransientObjectIndex(failAfterFirstTouch: true);
      final coordinator = CloudCacheCoordinator();
      addTearDown(coordinator.close);
      final repository = EditorSaveRepository(
        api: CloudMailApi(_StatTransport([node, node])),
        authRepository: auth,
        writeTransport: _RecordingWriteTransport(),
        offlineFileIndex: _MemoryOfflineFileIndex(),
        transientObjectIndex: transient,
        cacheRoot: root,
        coordinator: coordinator,
      );
      addTearDown(repository.close);

      final result = await repository.save(
        EditorSaveBaseline(path: node.path, hash: hash, size: bytes.length),
        bytes,
      );

      expect(result.isPartialSuccess, isTrue);
      expect(result.ownershipPolicy, EditorOwnershipPolicy.onlineOnly);
      expect(
        result.partialSuccess?.localFailure.type,
        EditorSaveFailureType.disk,
      );
      expect(transient.touchCalls, 2);
    },
  );

  test(
    'rejects editor content above the 10 MiB limit before writing',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-editor');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final hash = calculateCloudHash(const [1]);
      final node = _file('/docs/large.txt', hash, 1);
      final writer = _RecordingWriteTransport();
      final coordinator = CloudCacheCoordinator();
      addTearDown(coordinator.close);
      final repository = EditorSaveRepository(
        api: CloudMailApi(_StatTransport([node])),
        authRepository: auth,
        writeTransport: writer,
        offlineFileIndex: _MemoryOfflineFileIndex(),
        cacheRoot: root,
        coordinator: coordinator,
      );
      addTearDown(repository.close);

      await expectLater(
        repository.save(
          EditorSaveBaseline(path: node.path, hash: hash, size: 1),
          List<int>.filled(editorMaxBytes + 1, 0),
        ),
        throwsA(
          isA<EditorSaveFailure>().having(
            (failure) => failure.type,
            'type',
            EditorSaveFailureType.invalidRequest,
          ),
        ),
      );
      expect(writer.conflicts, isEmpty);
    },
  );
}

CloudNode _file(String path, String hash, int size) => CloudNode(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.file,
  hash: hash,
  size: size,
);

Future<AuthRepository> _authenticatedRepository() async {
  final session = CloudSession(
    email: 'editor@mail.ru',
    accessToken: 'access',
    refreshToken: 'refresh',
    csrfToken: 'csrf',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );
  final store = MemorySessionStore()..session = session;
  final repository = AuthRepository(api: _AuthApi(), store: store);
  await repository.restore();
  return repository;
}

final class _AuthApi implements AuthApi {
  @override
  Future<CloudSession> login({
    required String email,
    required String password,
  }) async => throw const AuthFailure(AuthFailureType.authRequired, 'unused');

  @override
  Future<CloudSession> refresh(CloudSession session) async => session;

  @override
  void close() {}
}

final class _StatTransport implements CloudTransport {
  _StatTransport(this._nodes);

  final List<CloudNode> _nodes;
  final paths = <String>[];

  @override
  Future<CloudResponse> get(
    String endpoint, {
    Map<String, String> query = const {},
    bool includeCsrfQuery = false,
  }) async {
    expect(endpoint, 'file');
    expect(includeCsrfQuery, isFalse);
    final node = _nodes.removeAt(0);
    paths.add(query['home']!);
    final body = <String, Object?>{
      'home': node.path,
      'name': node.name,
      'type': 'file',
      'hash': node.hash,
      'size': node.size,
    };
    return CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(jsonEncode({'status': 200, 'body': body})),
    );
  }

  @override
  void close() {}
}

final class _RecordingWriteTransport implements EditorWriteTransport {
  _RecordingWriteTransport({this.returnedPath, this.failure});

  final conflicts = <CloudWriteConflictMode>[];
  final String? returnedPath;
  final CloudWriteFailure? failure;
  File? lastSource;

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
    cancellation?.throwIfCancelled();
    lastSource = source;
    conflicts.add(conflict);
    final failure = this.failure;
    if (failure != null) throw failure;
    return CloudWriteResult(
      identity: CloudUploadIdentity(hash: expectedHash, size: expectedSize),
      requestedPath: remotePath,
      returnedPath: returnedPath ?? remotePath,
      conflict: conflict,
    );
  }

  @override
  void close() {}
}

final class _MemoryOfflineFileIndex implements OfflineFileIndex {
  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {}

  @override
  Future<List<OfflineFileRecord>> list(String email) async => const [];

  @override
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  ) async => const {};

  @override
  Future<bool> hasHashReference(String email, String hash) async => false;

  @override
  Future<void> remove(String email, String path) async {}

  @override
  Future<void> clearAccount(String email) async {}

  @override
  Future<void> close() async {}
}

final class _MemoryTransientObjectIndex implements TransientObjectIndex {
  _MemoryTransientObjectIndex({this.failAfterFirstTouch = false});

  final records = <String, TransientObjectRecord>{};
  final bool failAfterFirstTouch;
  int touchCalls = 0;

  @override
  Future<void> touchTransient(
    String email,
    TransientObjectRecord record,
  ) async {
    touchCalls++;
    if (failAfterFirstTouch && touchCalls > 1) {
      throw StateError('local transient storage unavailable');
    }
    records['${email.toLowerCase()}:${record.hash}'] = record;
  }

  @override
  Future<List<TransientObjectRecord>> listTransient(String email) async =>
      records.values.toList(growable: false);

  @override
  Future<void> removeTransient(String email, String hash) async {
    records.remove('${email.toLowerCase()}:${hash.toUpperCase()}');
  }

  @override
  Future<bool> hasTransientReference(String email, String hash) async =>
      records.containsKey('${email.toLowerCase()}:${hash.toUpperCase()}');
}
