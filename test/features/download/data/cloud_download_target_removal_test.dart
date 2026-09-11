import 'dart:io';

import 'package:easy_cloud/cloud_mail/api/cloud_mail_api.dart';
import 'package:easy_cloud/cloud_mail/transport/cloud_transport.dart';
import 'package:easy_cloud/features/auth/application/auth_repository.dart';
import 'package:easy_cloud/features/auth/data/cloud_auth_api.dart';
import 'package:easy_cloud/features/auth/data/session_store.dart';
import 'package:easy_cloud/features/auth/domain/cloud_session.dart';
import 'package:easy_cloud/features/download/data/cloud_download_repository.dart';
import 'package:easy_cloud/features/download/domain/download.dart';
import 'package:easy_cloud/features/offline/data/sqlite_offline_file_index.dart';
import 'package:easy_cloud/features/offline/domain/offline_target.dart';
import 'package:easy_cloud/features/offline/domain/offline_file_record.dart';
import 'package:easy_cloud/features/offline/domain/transient_object_record.dart';
import 'package:easy_cloud/local/cache/cloud_cache_coordinator.dart';
import 'package:easy_cloud/local/cache/application_cache_root.dart';
import 'package:easy_cloud/local/cache/content_addressed_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'target removal keeps shared direct and transient ownership safe',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-target-gc',
      );
      final index = SqliteOfflineFileIndex(
        rootProvider: FixedCacheRoot(root),
        databaseFactory: databaseFactoryFfi,
      );
      final auth = await _auth();
      final coordinator = CloudCacheCoordinator();
      final repository = CloudDownloadRepository(
        api: const CloudMailApi(_NoopCloudTransport()),
        transport: _NoopDownloadTransport(),
        authRepository: auth,
        offlineFileIndex: index,
        cacheRoot: root,
        coordinator: coordinator,
      );
      addTearDown(() async {
        await repository.close();
        await coordinator.close();
        auth.close();
        await index.close();
        await root.delete(recursive: true);
      });

      const hash = '00112233445566778899AABBCCDDEEFF00112233';
      await index.upsertTarget('user@mail.ru', _target('/target'));
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/target', '/target/file.txt', hash: hash),
      );
      await index.upsert(
        'user@mail.ru',
        OfflineFileRecord(
          path: '/direct.txt',
          name: 'direct.txt',
          hash: hash,
          size: 1,
          cachedAt: DateTime.utc(2025),
        ),
      );
      await index.touchTransient(
        'user@mail.ru',
        TransientObjectRecord(
          hash: hash,
          size: 1,
          lastAccessedAt: DateTime.utc(2025),
        ),
      );
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'user@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await object.parent.create(recursive: true);
      await object.writeAsBytes(const [1]);

      await repository.removeTarget(
        '/target',
        expectedEmail: 'user@mail.ru',
        targetIncarnation: 'test-incarnation',
      );

      expect(await index.getTarget('user@mail.ru', '/target'), isNull);
      expect(await index.list('user@mail.ru'), hasLength(1));
      expect(await index.hasTransientReference('user@mail.ru', hash), isTrue);
      expect(await object.exists(), isTrue);
    },
  );

  test(
    'target removal never restores ownership for an unusable CAS path',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-target-gc',
      );
      final index = SqliteOfflineFileIndex(
        rootProvider: FixedCacheRoot(root),
        databaseFactory: databaseFactoryFfi,
      );
      final auth = await _auth();
      final coordinator = CloudCacheCoordinator();
      final repository = CloudDownloadRepository(
        api: const CloudMailApi(_NoopCloudTransport()),
        transport: _NoopDownloadTransport(),
        authRepository: auth,
        offlineFileIndex: index,
        cacheRoot: root,
        coordinator: coordinator,
      );
      addTearDown(() async {
        await repository.close();
        await coordinator.close();
        auth.close();
        await index.close();
        await root.delete(recursive: true);
      });

      const hash = '00112233445566778899AABBCCDDEEFF00112233';
      await index.upsertTarget('user@mail.ru', _target('/target'));
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/target', '/target/file.txt', hash: hash),
      );
      await index.updateTarget(
        'user@mail.ru',
        _target('/target', state: OfflineTargetState.removing),
      );
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'user@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await Directory(object.path).create(recursive: true);

      await expectLater(
        repository.removeTarget(
          '/target',
          expectedEmail: 'user@mail.ru',
          targetIncarnation: 'test-incarnation',
        ),
        throwsA(isA<DownloadFailure>()),
      );
      expect(
        (await index.getTarget('user@mail.ru', '/target'))?.state,
        OfflineTargetState.removing,
      );
      expect(
        await index.listTargetFiles('user@mail.ru', '/target'),
        hasLength(1),
      );
    },
  );

  test(
    'filesystem cleanup failure preserves a removing target intent',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-target-gc',
      );
      final index = SqliteOfflineFileIndex(
        rootProvider: FixedCacheRoot(root),
        databaseFactory: databaseFactoryFfi,
      );
      final auth = await _auth();
      final coordinator = CloudCacheCoordinator();
      final repository = CloudDownloadRepository(
        api: const CloudMailApi(_NoopCloudTransport()),
        transport: _NoopDownloadTransport(),
        authRepository: auth,
        offlineFileIndex: index,
        cacheRoot: root,
        coordinator: coordinator,
      );
      addTearDown(() async {
        await repository.close();
        await coordinator.close();
        auth.close();
        await index.close();
        await root.delete(recursive: true);
      });

      const hash = '00112233445566778899AABBCCDDEEFF00112233';
      await index.upsertTarget('user@mail.ru', _target('/target'));
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/target', '/target/file.txt', hash: hash),
      );
      await index.updateTarget(
        'user@mail.ru',
        _target('/target', state: OfflineTargetState.removing),
      );
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'user@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await Directory(object.path).create(recursive: true);
      await File('${object.path}/child').writeAsString('not empty');

      await expectLater(
        repository.removeTarget(
          '/target',
          expectedEmail: 'user@mail.ru',
          targetIncarnation: 'test-incarnation',
        ),
        throwsA(isA<DownloadFailure>()),
      );
      expect(
        (await index.getTarget('user@mail.ru', '/target'))?.state,
        OfflineTargetState.removing,
      );
      expect(
        await index.listTargetFiles('user@mail.ru', '/target'),
        hasLength(1),
      );
    },
  );
}

OfflineTargetRecord _target(
  String path, {
  OfflineTargetState state = OfflineTargetState.ready,
}) => OfflineTargetRecord(
  targetPath: path,
  targetIncarnation: 'test-incarnation',
  targetName: path.substring(path.lastIndexOf('/') + 1),
  state: state,
  scanComplete: true,
  estimateHasUnknown: true,
  createdAt: DateTime.utc(2025),
  updatedAt: DateTime.utc(2025),
);

OfflineTargetFileRecord _targetFile(
  String targetPath,
  String filePath, {
  required String hash,
}) => OfflineTargetFileRecord(
  targetPath: targetPath,
  targetIncarnation: 'test-incarnation',
  filePath: filePath,
  name: filePath.substring(filePath.lastIndexOf('/') + 1),
  hash: hash,
  size: 1,
  readiness: OfflineReadiness.ready,
  bytesDone: 1,
  updatedAt: DateTime.utc(2025),
);

Future<AuthRepository> _auth() async {
  final store = MemorySessionStore()..session = _session();
  final auth = AuthRepository(api: _AuthApi(), store: store);
  await auth.restore();
  return auth;
}

CloudSession _session() => CloudSession(
  email: 'user@mail.ru',
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

final class _NoopCloudTransport implements CloudTransport {
  const _NoopCloudTransport();

  @override
  Future<CloudResponse> get(
    String endpoint, {
    Map<String, String> query = const {},
    bool includeCsrfQuery = false,
  }) => throw UnimplementedError();

  @override
  void close() {}
}

final class _NoopDownloadTransport implements DownloadTransport {
  @override
  Future<DownloadResult> download(
    DownloadRequest request, {
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellation,
  }) => throw UnimplementedError();

  @override
  void close() {}
}
