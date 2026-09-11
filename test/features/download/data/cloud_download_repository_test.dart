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
import 'package:easy_cloud/features/download/application/download_repository.dart';
import 'package:easy_cloud/features/download/data/cloud_download_repository.dart';
import 'package:easy_cloud/features/download/domain/download.dart';
import 'package:easy_cloud/features/offline/application/offline_file_index.dart';
import 'package:easy_cloud/local/cache/cloud_cache_coordinator.dart';
import 'package:easy_cloud/local/cache/content_addressed_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('downloads, verifies, indexes, and reports ordered phases', () async {
    final payload = utf8.encode('fresh download');
    final hash = calculateCloudHash(payload);
    final modifiedAt = DateTime.utc(2025, 2, 3, 4, 5, 6);
    final root = await Directory.systemTemp.createTemp('easy-cloud-download');
    addTearDown(() => root.delete(recursive: true));

    final index = _MemoryOfflineFileIndex();
    final auth = await _authenticatedRepository(email: ' Test@Mail.RU ');
    addTearDown(auth.close);
    final statTransport = _StatTransport([
      _file(
        '/stale.txt',
        payload.length,
        ' ${hash.toLowerCase()} ',
        name: 'fresh-name.txt',
        modifiedAt: modifiedAt,
        revision: 'revision-2',
        globalRevision: 'global-revision-2',
      ),
    ]);
    final downloadTransport = _DownloadTransport(payload);
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: statTransport,
      downloadTransport: downloadTransport,
      index: index,
    );
    addTearDown(repository.close);

    final events = <DownloadProgress>[];
    final indexedAtBefore = DateTime.now().toUtc();
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
    final indexedAtAfter = DateTime.now().toUtc();

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

    final records = await index.list(' TEST@MAIL.RU ');
    expect(index.upsertCalls, 1);
    expect(index.records.keys, contains('test@mail.ru:/stale.txt'));
    expect(records, hasLength(1));
    final record = records.single;
    expect(record.path, '/stale.txt');
    expect(record.name, 'fresh-name.txt');
    expect(record.hash, hash);
    expect(record.size, payload.length);
    expect(record.modifiedAt?.isAtSameMomentAs(modifiedAt), isTrue);
    expect(record.modifiedAt?.isUtc, isTrue);
    expect(record.revision, 'revision-2');
    expect(record.globalRevision, 'global-revision-2');
    expect(record.cachedAt.isUtc, isTrue);
    expect(
      record.cachedAt.isAfter(
        indexedAtBefore.subtract(const Duration(seconds: 1)),
      ),
      isTrue,
    );
    expect(
      record.cachedAt.isBefore(indexedAtAfter.add(const Duration(seconds: 1))),
      isTrue,
    );
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
      final index = _MemoryOfflineFileIndex();
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
        index: index,
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
      final records = await index.list('test@mail.ru');
      expect(index.upsertCalls, 1);
      expect(records, hasLength(1));
      expect(records.single.path, '/cached.txt');
      expect(records.single.name, 'cached.txt');
      expect(records.single.hash, hash);
      expect(records.single.size, payload.length);
    },
  );

  test(
    'target cache hit publishes membership before result and removes transient',
    () async {
      final payload = utf8.encode('target cache hit');
      final hash = calculateCloudHash(payload);
      final modifiedAt = DateTime.utc(2025, 3, 4, 5, 6, 7);
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
      await index.upsertTargetFile(
        'test@mail.ru',
        _targetFileRecord(
          '/target',
          '/target/file.txt',
          name: 'planned-name.txt',
          readiness: OfflineReadiness.queued,
        ),
      );
      await index.touchTransient(
        'test@mail.ru',
        _transientRecord(hash, payload.length, 1),
      );
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await object.parent.create(recursive: true);
      await object.writeAsBytes(payload);
      final releaseTransient = Completer<void>();
      final transientRemovalStarted = Completer<void>();
      index.transientRemovalGate = () => releaseTransient.future;
      index.transientRemovalStarted = transientRemovalStarted;
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file(
            '/target/file.txt',
            payload.length,
            hash,
            name: 'fresh-name.txt',
            modifiedAt: modifiedAt,
            revision: 'revision-2',
            globalRevision: 'global-revision-2',
          ),
        ]),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      final handle = repository.startTarget(
        _file(
          '/target/file.txt',
          1,
          '00112233445566778899AABBCCDDEEFF00112233',
        ),
        targetPath: '/target/',
        expectedEmail: 'test@mail.ru',
        targetIncarnation: 'test-incarnation',
      );
      final resultFuture = handle.result;
      await transientRemovalStarted.future;

      final ready = await index.getTargetFile(
        'test@mail.ru',
        '/target',
        '/target/file.txt',
      );
      expect(ready?.targetPath, '/target');
      expect(ready?.filePath, '/target/file.txt');
      expect(ready?.name, 'planned-name.txt');
      expect(ready?.hash, hash);
      expect(ready?.size, payload.length);
      expect(ready?.modifiedAt, modifiedAt);
      expect(ready?.revision, 'revision-2');
      expect(ready?.globalRevision, 'global-revision-2');
      expect(ready?.readiness, OfflineReadiness.ready);
      expect(ready?.bytesDone, payload.length);
      expect(index.records, isEmpty);
      expect(index.upsertCalls, 0);
      expect(index.targetEvents, [
        'markTargetFileReady',
        'targetReady',
        'removeTransient',
      ]);
      expect(await index.hasTransientReference('test@mail.ru', hash), isTrue);

      releaseTransient.complete();
      final result = await resultFuture;
      expect(result.path, object.path);
      expect(await index.hasTransientReference('test@mail.ru', hash), isFalse);
    },
  );

  test(
    'target download verifies and updates only its existing membership',
    () async {
      final payload = utf8.encode('target download');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
      await index.upsertTargetFile(
        'test@mail.ru',
        _targetFileRecord(
          '/target',
          '/target/file.txt',
          name: 'membership-name.txt',
          readiness: OfflineReadiness.queued,
        ),
      );
      final statTransport = _StatTransport([
        _file(
          '/target/file.txt',
          payload.length,
          hash,
          name: 'remote-name.txt',
          modifiedAt: DateTime.utc(2025, 4),
          revision: 'remote-revision',
          globalRevision: 'remote-global-revision',
        ),
      ]);
      final downloadTransport = _DownloadTransport(payload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
        index: index,
      );
      addTearDown(repository.close);

      final result = await repository
          .startTarget(
            _node('/target/file.txt'),
            targetPath: '/target',
            expectedEmail: 'test@mail.ru',
            targetIncarnation: 'test-incarnation',
          )
          .result;

      expect(await result.readAsBytes(), payload);
      expect(statTransport.paths, ['/target/file.txt']);
      expect(downloadTransport.calls, 1);
      expect(index.records, isEmpty);
      expect(index.upsertCalls, 0);
      expect(index.targetReadyCalls, 1);
      final ready = await index.getTargetFile(
        'test@mail.ru',
        '/target',
        '/target/file.txt',
      );
      expect(ready?.name, 'membership-name.txt');
      expect(ready?.hash, hash);
      expect(ready?.size, payload.length);
      expect(ready?.readiness, OfflineReadiness.ready);
      expect(ready?.bytesDone, payload.length);
    },
  );

  test(
    'target input rejects folders and paths outside the target synchronously',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport(const []),
        downloadTransport: _DownloadTransport(const []),
      );
      addTearDown(repository.close);

      expect(
        () => repository.startTarget(
          const CloudNode(
            path: '/target/folder',
            name: 'folder',
            type: CloudNodeType.folder,
          ),
          targetPath: '/target',
          expectedEmail: 'test@mail.ru',
          targetIncarnation: 'test-incarnation',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.startTarget(
          _node('/targeted/file.txt'),
          targetPath: '/target',
          expectedEmail: 'test@mail.ru',
          targetIncarnation: 'test-incarnation',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.startTarget(
          _node('/target/file.txt'),
          targetPath: '../',
          expectedEmail: 'test@mail.ru',
          targetIncarnation: 'test-incarnation',
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test(
    'missing target membership cancels without transport or recreation',
    () async {
      final payload = utf8.encode('missing target membership');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
      final downloadTransport = _DownloadTransport(payload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file('/target/file.txt', payload.length, hash),
        ]),
        downloadTransport: downloadTransport,
        index: index,
      );
      addTearDown(repository.close);

      final handle = repository.startTarget(
        _node('/target/file.txt'),
        targetPath: '/target',
        expectedEmail: 'test@mail.ru',
        targetIncarnation: 'test-incarnation',
      );
      await expectLater(handle.result, throwsA(isA<DownloadCancelled>()));

      expect(downloadTransport.calls, 0);
      expect(index.targetReadyCalls, 0);
      expect(index.records, isEmpty);
      expect(index.targetFiles, isEmpty);
    },
  );

  test('target session switch cancels before publishing membership', () async {
    final payload = utf8.encode('target session switch');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-target');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final index = _MemoryOfflineFileIndex();
    await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
    await index.upsertTargetFile(
      'test@mail.ru',
      _targetFileRecord('/target', '/target/file.txt'),
    );
    final lookupStarted = Completer<void>();
    final releaseLookup = Completer<void>();
    index.targetLookupGate = () {
      if (!lookupStarted.isCompleted) lookupStarted.complete();
      return releaseLookup.future;
    };
    final downloadTransport = _DownloadTransport(payload);
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport([
        _file('/target/file.txt', payload.length, hash),
      ]),
      downloadTransport: downloadTransport,
      index: index,
    );
    addTearDown(repository.close);

    final handle = repository.startTarget(
      _node('/target/file.txt'),
      targetPath: '/target',
      expectedEmail: 'test@mail.ru',
      targetIncarnation: 'test-incarnation',
    );
    await lookupStarted.future;
    final logout = auth.logout();
    releaseLookup.complete();
    await logout;

    await expectLater(handle.result, throwsA(isA<DownloadCancelled>()));
    expect(downloadTransport.calls, 0);
    expect(index.targetReadyCalls, 0);
    expect(
      (await index.getTargetFile(
        'test@mail.ru',
        '/target',
        '/target/file.txt',
      ))?.readiness,
      OfflineReadiness.queued,
    );
  });

  test(
    'target cancellation during readiness write does not leave ready row',
    () async {
      final payload = utf8.encode('target readiness cancellation');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final readinessStarted = Completer<void>();
      final releaseReadiness = Completer<void>();
      final index = _MemoryOfflineFileIndex()
        ..targetReadyCompleted = readinessStarted
        ..targetReadyGate = () => releaseReadiness.future;
      await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
      await index.upsertTargetFile(
        'test@mail.ru',
        _targetFileRecord('/target', '/target/file.txt'),
      );
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file('/target/file.txt', payload.length, hash),
        ]),
        downloadTransport: _DownloadTransport(payload),
        index: index,
      );
      addTearDown(repository.close);

      final handle = repository.startTarget(
        _node('/target/file.txt'),
        targetPath: '/target',
        expectedEmail: 'test@mail.ru',
        targetIncarnation: 'test-incarnation',
      );
      await readinessStarted.future;
      handle.cancel();
      releaseReadiness.complete();

      await expectLater(handle.result, throwsA(isA<DownloadCancelled>()));
      expect(
        (await index.getTargetFile(
          'test@mail.ru',
          '/target',
          '/target/file.txt',
        ))?.readiness,
        OfflineReadiness.queued,
      );
    },
  );

  test('a target membership removed while queued is not recreated', () async {
    final payload = utf8.encode('target queued cancellation');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-target');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final index = _MemoryOfflineFileIndex();
    await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
    await index.upsertTargetFile(
      'test@mail.ru',
      _targetFileRecord('/target', '/target/file.txt'),
    );
    final targetLookupStarted = Completer<void>();
    final releaseTargetLookup = Completer<void>();
    index.targetLookupGate = () {
      if (!targetLookupStarted.isCompleted) targetLookupStarted.complete();
      return releaseTargetLookup.future;
    };
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final statTransport = _StatTransport([
      _file('/direct.txt', payload.length, hash),
      _file('/target/file.txt', payload.length, hash),
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
      index: index,
    );
    addTearDown(repository.close);

    final direct = repository.start(_node('/direct.txt'));
    await writeStarted.future;
    final target = repository.startTarget(
      _node('/target/file.txt'),
      targetPath: '/target',
      expectedEmail: 'test@mail.ru',
      targetIncarnation: 'test-incarnation',
    );
    await targetLookupStarted.future;
    releaseTargetLookup.complete();
    await _settle();
    index.targetFiles.remove(
      _targetFileKey('test@mail.ru', '/target', '/target/file.txt'),
    );
    releaseWrite.complete();

    await direct.result;
    await expectLater(target.result, throwsA(isA<DownloadCancelled>()));
    expect(downloadTransport.calls, 1);
    expect(index.targetReadyCalls, 1);
    expect(
      await index.getTargetFile('test@mail.ru', '/target', '/target/file.txt'),
      isNull,
    );
  });

  test(
    'target metadata failure fails after CAS commit without false readiness',
    () async {
      final payload = utf8.encode('target database failure');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex()
        ..nextTargetReadyFailure = StateError('target database unavailable');
      await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
      await index.upsertTargetFile(
        'test@mail.ru',
        _targetFileRecord('/target', '/target/file.txt'),
      );
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file('/target/file.txt', payload.length, hash),
        ]),
        downloadTransport: _DownloadTransport(payload),
        index: index,
      );
      addTearDown(repository.close);

      await expectLater(
        repository
            .startTarget(
              _node('/target/file.txt'),
              targetPath: '/target',
              expectedEmail: 'test@mail.ru',
              targetIncarnation: 'test-incarnation',
            )
            .result,
        throwsA(isA<StateError>()),
      );

      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final object = await cache.objectFile(hash);
      expect(await object.exists(), isTrue);
      expect(index.targetReadyCalls, 1);
      expect(
        (await index.getTargetFile(
          'test@mail.ru',
          '/target',
          '/target/file.txt',
        ))?.readiness,
        OfflineReadiness.queued,
      );
      expect(index.records, isEmpty);
    },
  );

  test(
    'opens a matching direct binding from a verified cache object',
    () async {
      final payload = utf8.encode('direct offline object');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-open');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      final record = _offlineRecord('/direct.txt', hash, size: payload.length);
      index.records['test@mail.ru:/direct.txt'] = record;
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await object.parent.create(recursive: true);
      await object.writeAsBytes(payload);
      final statTransport = _StatTransport(const []);
      final downloadTransport = _DownloadTransport(const []);
      final DownloadRepository repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
        index: index,
      );
      addTearDown(repository.close);

      final result = await repository
          .startOpen(_file('/direct.txt', payload.length, hash))
          .result;

      expect(result.path, object.path);
      expect(await result.readAsBytes(), payload);
      expect(statTransport.calls, 0);
      expect(downloadTransport.calls, 0);
      expect(index.upsertCalls, 0);
      expect(await index.hasTransientReference('test@mail.ru', hash), isTrue);
    },
  );

  test(
    'opens an inherited ready target membership without network access',
    () async {
      final payload = utf8.encode('inherited target object');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-open');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
      await index.upsertTargetFile(
        'test@mail.ru',
        _targetFileRecord(
          '/target',
          '/target/inherited.txt',
          hash: hash,
          size: payload.length,
          readiness: OfflineReadiness.ready,
        ),
      );
      await _writeObject(root, 'test@mail.ru', hash, payload);
      final statTransport = _StatTransport(const []);
      final downloadTransport = _DownloadTransport(const []);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
        index: index,
      );
      addTearDown(repository.close);

      final result = await repository
          .startOpen(_node('/target/inherited.txt'))
          .result;

      expect(await result.readAsBytes(), payload);
      expect(statTransport.calls, 0);
      expect(downloadTransport.calls, 0);
      expect(index.upsertCalls, 0);
      expect(index.targetReadyCalls, 0);
      expect(await index.hasTransientReference('test@mail.ru', hash), isTrue);
    },
  );

  test(
    'repairs an inherited target object through its unchanged membership',
    () async {
      final payload = utf8.encode('repaired inherited target object');
      final corrupt = utf8.encode('corrupt inherited target object!');
      expect(corrupt.length, payload.length);
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-open');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
      await index.upsertTargetFile(
        'test@mail.ru',
        _targetFileRecord(
          '/target',
          '/target/inherited.txt',
          name: 'planned.txt',
          hash: hash,
          size: payload.length,
          readiness: OfflineReadiness.ready,
        ),
      );
      await _writeObject(root, 'test@mail.ru', hash, corrupt);
      final statTransport = _StatTransport([
        _file(
          '/target/inherited.txt',
          payload.length,
          hash,
          name: 'remote.txt',
        ),
      ]);
      final downloadTransport = _DownloadTransport(payload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
        index: index,
      );
      addTearDown(repository.close);

      final result = await repository
          .startOpen(_node('/target/inherited.txt'))
          .result;

      expect(await result.readAsBytes(), payload);
      expect(statTransport.paths, ['/target/inherited.txt']);
      expect(downloadTransport.calls, 1);
      expect(index.upsertCalls, 0);
      expect(index.targetReadyCalls, 1);
      final membership = await index.getTargetFile(
        'test@mail.ru',
        '/target',
        '/target/inherited.txt',
      );
      expect(membership?.readiness, OfflineReadiness.ready);
      expect(membership?.hash, hash);
      expect(membership?.size, payload.length);
      expect(membership?.name, 'planned.txt');
      expect(await index.hasTransientReference('test@mail.ru', hash), isTrue);
    },
  );

  test(
    'does not repair an inherited membership removed while opening',
    () async {
      final payload = utf8.encode('removed inherited target object');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-open');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final lookupStarted = Completer<void>();
      final releaseLookup = Completer<void>();
      var targetLookups = 0;
      final index = _MemoryOfflineFileIndex()
        ..targetLookupGate = () {
          targetLookups++;
          if (targetLookups == 2) {
            lookupStarted.complete();
            return releaseLookup.future;
          }
          return Future<void>.value();
        };
      await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
      await index.upsertTargetFile(
        'test@mail.ru',
        _targetFileRecord(
          '/target',
          '/target/inherited.txt',
          hash: hash,
          size: payload.length,
          readiness: OfflineReadiness.ready,
        ),
      );
      final statTransport = _StatTransport([
        _file('/target/inherited.txt', payload.length, hash),
      ]);
      final downloadTransport = _DownloadTransport(payload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
        index: index,
      );
      addTearDown(repository.close);

      final opening = repository.startOpen(_node('/target/inherited.txt'));
      await lookupStarted.future;
      await index.removeTarget(
        'test@mail.ru',
        '/target',
        targetIncarnation: 'test-incarnation',
      );
      releaseLookup.complete();

      await expectLater(opening.result, throwsA(isA<DownloadCancelled>()));
      expect(statTransport.calls, 0);
      expect(downloadTransport.calls, 0);
      expect(index.targetReadyCalls, 0);
    },
  );

  test(
    'opens an online-only file without creating an offline binding',
    () async {
      final payload = utf8.encode('online only object');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-open');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      final statTransport = _StatTransport([
        _file('/online.txt', payload.length, hash),
      ]);
      final downloadTransport = _DownloadTransport(payload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
        index: index,
      );
      addTearDown(repository.close);

      final result = await repository.startOpen(_node('/online.txt')).result;

      expect(await result.readAsBytes(), payload);
      expect(downloadTransport.calls, 1);
      expect(index.upsertCalls, 0);
      expect(index.records, isEmpty);
      expect(await result.length(), payload.length);
      expect(await calculateCloudFileHash(result), hash);
      expect(await index.hasTransientReference('test@mail.ru', hash), isTrue);
    },
  );

  test('persistent start removes a same-account transient reference', () async {
    final payload = utf8.encode('persistent takes ownership');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-download');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final index = _MemoryOfflineFileIndex();
    await index.touchTransient('test@mail.ru', _transientRecord(hash, 99, 1));
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport([
        _file('/persistent.txt', payload.length, hash),
      ]),
      downloadTransport: _DownloadTransport(payload),
      index: index,
    );
    addTearDown(repository.close);

    await repository.start(_node('/persistent.txt')).result;

    expect(await index.hasTransientReference('test@mail.ru', hash), isFalse);
    expect(await index.list('test@mail.ru'), hasLength(1));
  });

  test('removing an offline binding preserves a transient reference', () async {
    final payload = utf8.encode('transient keeps object');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-remove');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final index = _MemoryOfflineFileIndex();
    await index.upsert('test@mail.ru', _offlineRecord('/pinned.txt', hash));
    await index.touchTransient('test@mail.ru', _transientRecord(hash, 99, 1));
    final cache = ContentAddressedFileCache(root: root, email: 'test@mail.ru');
    final object = await cache.objectFile(hash);
    await object.parent.create(recursive: true);
    await object.writeAsBytes(payload);
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport(const []),
      downloadTransport: _DownloadTransport(const []),
      index: index,
    );
    addTearDown(repository.close);

    await repository.removeOffline(_node('/pinned.txt'));

    expect(await object.exists(), isTrue);
    expect(await index.hasTransientReference('test@mail.ru', hash), isTrue);
    expect(await index.list('test@mail.ru'), isEmpty);
  });

  test(
    'repairs a corrupt direct object without changing its binding',
    () async {
      final payload = utf8.encode('correct direct contents');
      final corrupt = utf8.encode('corrupt direct contents');
      expect(corrupt.length, payload.length);
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-open');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      index.records['test@mail.ru:/repair.txt'] = _offlineRecord(
        '/repair.txt',
        hash,
        size: payload.length,
      );
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await object.parent.create(recursive: true);
      await object.writeAsBytes(corrupt);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport(const []),
        downloadTransport: _DownloadTransport(payload),
        index: index,
      );
      addTearDown(repository.close);

      final result = await repository
          .startOpen(_file('/repair.txt', payload.length, hash))
          .result;

      expect(await result.readAsBytes(), payload);
      expect(await object.readAsBytes(), payload);
      expect(index.upsertCalls, 0);
      expect(await index.list('test@mail.ru'), hasLength(1));
      expect(await index.hasTransientReference('test@mail.ru', hash), isTrue);
    },
  );

  test('repairs a missing direct object without a persistent upsert', () async {
    final payload = utf8.encode('missing direct contents');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-open');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final index = _MemoryOfflineFileIndex();
    index.records['test@mail.ru:/missing.txt'] = _offlineRecord(
      '/missing.txt',
      hash,
      size: payload.length,
    );
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport(const []),
      downloadTransport: _DownloadTransport(payload),
      index: index,
    );
    addTearDown(repository.close);

    final result = await repository
        .startOpen(_file('/missing.txt', payload.length, hash))
        .result;

    expect(await result.readAsBytes(), payload);
    expect(index.upsertCalls, 0);
    expect(await index.list('test@mail.ru'), hasLength(1));
    expect(await index.hasTransientReference('test@mail.ru', hash), isTrue);
  });

  test(
    'session switch cancels an open before it can mutate the old account',
    () async {
      final payload = utf8.encode('session scoped open');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-open');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final lookupStarted = Completer<void>();
      final releaseLookup = Completer<void>();
      final index = _MemoryOfflineFileIndex()
        ..lookupGate = () {
          if (!lookupStarted.isCompleted) {
            lookupStarted.complete();
            return releaseLookup.future;
          }
          return Future<void>.value();
        };
      index.records['test@mail.ru:/session.txt'] = _offlineRecord(
        '/session.txt',
        hash,
        size: payload.length,
      );
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport(const []),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      final handle = repository.startOpen(
        _file('/session.txt', payload.length, hash),
      );
      await lookupStarted.future;
      final logout = auth.logout();
      releaseLookup.complete();
      await logout;

      await expectLater(handle.result, throwsA(isA<DownloadCancelled>()));
      expect(index.upsertCalls, 0);
      expect((await index.list('test@mail.ru')), hasLength(1));
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
      final coordinator = CloudCacheCoordinator();
      addTearDown(coordinator.close);
      final repository = CloudDownloadRepository(
        api: CloudMailApi(statTransport),
        transport: downloadTransport,
        authRepository: auth,
        offlineFileIndex: _MemoryOfflineFileIndex(),
        cacheFactory: (email) {
          factoryEmails.add(email);
          return ContentAddressedFileCache(root: root, email: email);
        },
        coordinator: coordinator,
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
    final index = _MemoryOfflineFileIndex();
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport([_file('/bad.txt', expected.length, hash)]),
      downloadTransport: _DownloadTransport(actual),
      index: index,
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
    expect(index.upsertCalls, 0);
    expect(index.records, isEmpty);
  });

  test(
    'size mismatch is typed and does not update the offline index',
    () async {
      final expected = utf8.encode('expected size');
      final actual = utf8.encode('short');
      final hash = calculateCloudHash(expected);
      final root = await Directory.systemTemp.createTemp('easy-cloud-download');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final index = _MemoryOfflineFileIndex();
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file('/bad-size.txt', expected.length, hash),
        ]),
        downloadTransport: _DownloadTransport(actual),
        index: index,
      );
      addTearDown(repository.close);

      final handle = repository.start(_node('/bad-size.txt'));
      await expectLater(
        handle.result,
        throwsA(
          isA<DownloadIntegrityFailure>()
              .having(
                (failure) => failure.type,
                'type',
                DownloadFailureType.integrity,
              )
              .having(
                (failure) => failure.actualSize,
                'actualSize',
                actual.length,
              ),
        ),
      );

      final paths = await cache.paths(hash);
      expect(await paths.objectFile.exists(), isFalse);
      expect(await paths.partFile.exists(), isFalse);
      expect(index.upsertCalls, 0);
      expect(index.records, isEmpty);
    },
  );

  test(
    'index failure preserves the verified object and retry uses a cache hit',
    () async {
      final payload = utf8.encode('recoverable index failure');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-download');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final indexFailure = StateError('offline index unavailable');
      final index = _MemoryOfflineFileIndex()..nextUpsertFailure = indexFailure;
      final statTransport = _StatTransport([
        _file('/retry.txt', payload.length, hash),
        _file('/retry.txt', payload.length, hash),
      ]);
      final downloadTransport = _DownloadTransport(payload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: statTransport,
        downloadTransport: downloadTransport,
        index: index,
      );
      addTearDown(repository.close);

      final first = repository.start(_node('/retry.txt'));
      await expectLater(first.result, throwsA(same(indexFailure)));

      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final object = await cache.objectFile(hash);
      expect(await object.exists(), isTrue);
      expect(await object.readAsBytes(), payload);
      expect(index.upsertCalls, 1);
      expect(index.records, isEmpty);
      expect(await index.hasTransientReference('test@mail.ru', hash), isFalse);

      final retryEvents = <DownloadProgress>[];
      final retry = repository.start(_node('/retry.txt'));
      final subscription = retry.progress.listen(retryEvents.add);
      final result = await retry.result;
      await subscription.cancel();

      expect(result.path, object.path);
      expect(await result.readAsBytes(), payload);
      expect(downloadTransport.calls, 1);
      expect(retryEvents.map((event) => event.phase), [
        DownloadPhase.resolving,
        DownloadPhase.committed,
      ]);
      expect(retryEvents.last.cacheHit, isTrue);
      expect(index.upsertCalls, 2);
      expect(await index.list('test@mail.ru'), hasLength(1));
    },
  );

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

    await repository.close();

    expect(downloadTransport.closed, isTrue);
    expect(statTransport.closed, isFalse);
    await repository.close();
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
    final closing = repository.close();
    expect(downloadTransport.closed, isFalse);

    await expectLater(handle.result, throwsA(isA<DownloadCancelled>()));
    await closing;
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

  test(
    'cancelling a queued open does not bypass or cancel the preceding write',
    () async {
      final payload = utf8.encode('queued open');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-open');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      final statTransport = _StatTransport([
        _file('/queued.txt', payload.length, hash),
        _file('/queued.txt', payload.length, hash),
        _file('/queued.txt', payload.length, hash),
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

      final first = repository.start(_node('/queued.txt'));
      await writeStarted.future;
      final queued = repository.startOpen(_node('/queued.txt'));
      await _settle();
      expect(statTransport.calls, 2);

      queued.cancel();
      await expectLater(
        queued.result.timeout(const Duration(seconds: 1)),
        throwsA(isA<DownloadCancelled>()),
      );
      expect(downloadTransport.calls, 1);

      final third = repository.startOpen(_node('/queued.txt'));
      await _settle();
      expect(downloadTransport.calls, 1);
      releaseWrite.complete();
      await Future.wait([first.result, third.result]);

      expect(downloadTransport.calls, 1);
      expect(downloadTransport.maxConcurrentWrites, 1);
    },
  );

  test(
    'removes one same-hash binding without deleting the shared object',
    () async {
      final payload = utf8.encode('shared offline object');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-remove');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await object.parent.create(recursive: true);
      await object.writeAsBytes(payload);
      await index.upsert('test@mail.ru', _offlineRecord('/first.txt', hash));
      await index.upsert('test@mail.ru', _offlineRecord('/second.txt', hash));
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport(const []),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      await repository.removeOffline(_node('/first.txt'));

      expect(await object.exists(), isTrue);
      expect(await index.list('test@mail.ru'), hasLength(1));
      expect((await index.list('test@mail.ru')).single.path, '/second.txt');
    },
  );

  test(
    'removes the last binding and deletes its object; absent is a no-op',
    () async {
      final payload = utf8.encode('last offline object');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-remove');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await object.parent.create(recursive: true);
      await object.writeAsBytes(payload);
      await index.upsert('test@mail.ru', _offlineRecord('/last.txt', hash));
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport(const []),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      await repository.removeOffline(_node('/last.txt'));
      await repository.removeOffline(_node('/missing.txt'));

      expect(await object.exists(), isFalse);
      expect(await index.list('test@mail.ru'), isEmpty);
      expect(index.removeCalls, 1);
    },
  );

  test(
    'stale removal cannot mutate the account after a session switch',
    () async {
      final payload = utf8.encode('stale removal');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-remove');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final lookupStarted = Completer<void>();
      final releaseLookup = Completer<void>();
      final index = _MemoryOfflineFileIndex()
        ..lookupGate = () {
          if (!lookupStarted.isCompleted) {
            lookupStarted.complete();
            return releaseLookup.future;
          }
          return Future<void>.value();
        };
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final object = await cache.objectFile(hash);
      await object.parent.create(recursive: true);
      await object.writeAsBytes(payload);
      await index.upsert('test@mail.ru', _offlineRecord('/stale.txt', hash));
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport(const []),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      final removal = repository.removeOffline(_node('/stale.txt'));
      await lookupStarted.future;
      final logout = auth.logout();
      releaseLookup.complete();
      await logout;

      await expectLater(removal, throwsA(isA<DownloadCancelled>()));
      expect(await index.list('test@mail.ru'), hasLength(1));
      expect(await object.exists(), isTrue);
    },
  );

  test('serializes removal with an active same-hash download', () async {
    final payload = utf8.encode('download and remove');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-remove');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final index = _MemoryOfflineFileIndex();
    await index.upsert('test@mail.ru', _offlineRecord('/pinned.txt', hash));
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport([_file('/new.txt', payload.length, hash)]),
      downloadTransport: _DownloadTransport(
        payload,
        started: writeStarted,
        releaseWrite: releaseWrite,
      ),
      index: index,
    );
    addTearDown(repository.close);

    final download = repository.start(_node('/new.txt'));
    await writeStarted.future;
    final removal = repository.removeOffline(_node('/pinned.txt'));
    await Future<void>.delayed(Duration.zero);
    expect(index.removeCalls, 0);

    releaseWrite.complete();
    await Future.wait([download.result, removal]);

    expect(index.removeCalls, 1);
    expect(await index.list('test@mail.ru'), hasLength(1));
    expect((await index.list('test@mail.ru')).single.path, '/new.txt');
    final object = await (ContentAddressedFileCache(
      root: root,
      email: 'test@mail.ru',
    )).objectFile(hash);
    expect(await object.exists(), isTrue);
  });

  test('close waits for active offline removal persistence', () async {
    final hash = calculateCloudHash(utf8.encode('delayed offline removal'));
    final root = await Directory.systemTemp.createTemp('easy-cloud-close');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final releaseRemoval = Completer<void>();
    final index = _MemoryOfflineFileIndex()
      ..removalStarted = Completer<void>()
      ..removalGate = () => releaseRemoval.future;
    await index.upsert('test@mail.ru', _offlineRecord('/delayed.txt', hash));
    final downloadTransport = _DownloadTransport(const []);
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport(const []),
      downloadTransport: downloadTransport,
      index: index,
    );

    final removal = repository.removeOffline(_node('/delayed.txt'));
    await index.removalStarted!.future;
    var closeCompleted = false;
    final closing = repository.close();
    closing.then((_) => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(closeCompleted, isFalse);
    expect(downloadTransport.closed, isFalse);

    releaseRemoval.complete();
    await expectLater(removal, throwsA(isA<DownloadCancelled>()));
    await closing;
    expect(downloadTransport.closed, isTrue);
  });

  test('close waits for active target removal persistence', () async {
    final payload = utf8.encode('delayed target removal');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-close');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final releaseRemoval = Completer<void>();
    final index = _MemoryOfflineFileIndex()
      ..targetRemovalStarted = Completer<void>()
      ..targetRemovalGate = () => releaseRemoval.future;
    await index.upsertTarget('test@mail.ru', _targetRecord('/folder'));
    await index.upsertTargetFile(
      'test@mail.ru',
      _targetFileRecord(
        '/folder',
        '/folder/file.txt',
        hash: hash,
        size: payload.length,
        readiness: OfflineReadiness.ready,
      ),
    );
    await _writeObject(root, 'test@mail.ru', hash, payload);
    final downloadTransport = _DownloadTransport(const []);
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport(const []),
      downloadTransport: downloadTransport,
      index: index,
    );

    final removal = repository.removeTarget(
      '/folder',
      expectedEmail: 'test@mail.ru',
      targetIncarnation: 'test-incarnation',
    );
    await index.targetRemovalStarted!.future;
    var closeCompleted = false;
    final closing = repository.close();
    closing.then((_) => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(closeCompleted, isFalse);
    expect(downloadTransport.closed, isFalse);

    releaseRemoval.complete();
    await removal;
    await closing;
    expect(downloadTransport.closed, isTrue);
  });

  test('filesystem cleanup failure is typed and leaves no binding', () async {
    final hash = calculateCloudHash(utf8.encode('cleanup failure'));
    final root = await Directory.systemTemp.createTemp('easy-cloud-remove');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final index = _MemoryOfflineFileIndex();
    final cache = ContentAddressedFileCache(root: root, email: 'test@mail.ru');
    final object = await cache.objectFile(hash);
    // A directory at the object path is rejected deterministically on every
    // platform; an open file can still be unlinked successfully on Unix.
    await Directory(object.path).create(recursive: true);
    await index.upsert('test@mail.ru', _offlineRecord('/broken.txt', hash));
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport(const []),
      downloadTransport: _DownloadTransport(const []),
      index: index,
    );
    addTearDown(repository.close);

    await expectLater(
      repository.removeOffline(_node('/broken.txt')),
      throwsA(
        isA<DownloadFailure>()
            .having((failure) => failure.type, 'type', DownloadFailureType.disk)
            .having(
              (failure) => failure.message,
              'message',
              isNot(contains(root.path)),
            ),
      ),
    );
    expect(await index.list('test@mail.ru'), isEmpty);
  });

  test(
    'prunes oldest transient objects per account but keeps pinned and current',
    () async {
      final oldPayload = utf8.encode('old transient');
      final recentPayload = utf8.encode('recent transient');
      final currentPayload = utf8.encode('current transient');
      final pinnedPayload = utf8.encode('pinned transient');
      final oldHash = calculateCloudHash(oldPayload);
      final recentHash = calculateCloudHash(recentPayload);
      final currentHash = calculateCloudHash(currentPayload);
      final pinnedHash = calculateCloudHash(pinnedPayload);
      final otherHash = calculateCloudHash(utf8.encode('other account'));
      final root = await Directory.systemTemp.createTemp('easy-cloud-lru');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();

      await _writeObject(root, 'test@mail.ru', oldHash, oldPayload);
      await _writeObject(root, 'test@mail.ru', recentHash, recentPayload);
      await _writeObject(root, 'test@mail.ru', currentHash, currentPayload);
      await _writeObject(root, 'test@mail.ru', pinnedHash, pinnedPayload);
      await _writeObject(root, 'other@mail.ru', otherHash, const [1]);
      await index.upsert(
        'test@mail.ru',
        _offlineRecord('/pinned.txt', pinnedHash),
      );
      await index.touchTransient(
        'test@mail.ru',
        _transientRecord(oldHash, 300000000, 1),
      );
      await index.touchTransient(
        'test@mail.ru',
        _transientRecord(recentHash, 250000000, 2),
      );
      await index.touchTransient(
        'test@mail.ru',
        _transientRecord(pinnedHash, 900000000, 1),
      );
      await index.touchTransient(
        'other@mail.ru',
        _transientRecord(otherHash, 900000000, 1),
      );

      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file('/current.txt', currentPayload.length, currentHash),
        ]),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      await repository.startOpen(_node('/current.txt')).result;

      expect(
        await index.hasTransientReference('test@mail.ru', oldHash),
        isFalse,
      );
      expect(
        await index.hasTransientReference('test@mail.ru', recentHash),
        isTrue,
      );
      expect(
        await index.hasTransientReference('test@mail.ru', currentHash),
        isTrue,
      );
      expect(
        await index.hasTransientReference('test@mail.ru', pinnedHash),
        isTrue,
      );
      expect(
        await index.hasTransientReference('other@mail.ru', otherHash),
        isTrue,
      );
      final oldObject = await ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      ).objectFile(oldHash);
      expect(await oldObject.exists(), isFalse);
    },
  );

  test(
    'allows the currently prepared object to exceed the cap temporarily',
    () async {
      final payload = utf8.encode('oversized current object');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-lru');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex()
        ..transientSizeOverride = 524288001;
      await _writeObject(root, 'test@mail.ru', hash, payload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file('/oversized.txt', payload.length, hash),
        ]),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      await repository.startOpen(_node('/oversized.txt')).result;

      expect(await index.hasTransientReference('test@mail.ru', hash), isTrue);
      final object = await ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      ).objectFile(hash);
      expect(await object.exists(), isTrue);
    },
  );

  test(
    'a next open releases the previous protected transient object',
    () async {
      final firstPayload = utf8.encode('first prepared object');
      final secondPayload = utf8.encode('second prepared object');
      final firstHash = calculateCloudHash(firstPayload);
      final secondHash = calculateCloudHash(secondPayload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-lru');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      await _writeObject(root, 'test@mail.ru', firstHash, firstPayload);
      await _writeObject(root, 'test@mail.ru', secondHash, secondPayload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file('/first.txt', firstPayload.length, firstHash),
          _file('/second.txt', secondPayload.length, secondHash),
        ]),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      await repository.startOpen(_node('/first.txt')).result;
      await index.touchTransient(
        'test@mail.ru',
        _transientRecord(firstHash, 524288001, 1),
      );
      await repository.startOpen(_node('/second.txt')).result;

      expect(
        await index.hasTransientReference('test@mail.ru', firstHash),
        isFalse,
      );
      expect(
        await index.hasTransientReference('test@mail.ru', secondHash),
        isTrue,
      );
    },
  );

  test('prune removes durable rows whose final object is missing', () async {
    final payload = utf8.encode('present current object');
    final currentHash = calculateCloudHash(payload);
    final missingHash = calculateCloudHash(utf8.encode('missing object'));
    final root = await Directory.systemTemp.createTemp('easy-cloud-lru');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final index = _MemoryOfflineFileIndex();
    await _writeObject(root, 'test@mail.ru', currentHash, payload);
    await index.touchTransient(
      'test@mail.ru',
      _transientRecord(missingHash, 1, 1),
    );
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport([
        _file('/current.txt', payload.length, currentHash),
      ]),
      downloadTransport: _DownloadTransport(const []),
      index: index,
    );
    addTearDown(repository.close);

    await repository.startOpen(_node('/current.txt')).result;

    expect(
      await index.hasTransientReference('test@mail.ru', missingHash),
      isFalse,
    );
  });

  test(
    'prune retains a transient row when its object cannot be deleted',
    () async {
      final currentPayload = utf8.encode('current object');
      final blockedPayload = utf8.encode('blocked object');
      final currentHash = calculateCloudHash(currentPayload);
      final blockedHash = calculateCloudHash(blockedPayload);
      final root = await Directory.systemTemp.createTemp('easy-cloud-lru');
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      await _writeObject(root, 'test@mail.ru', currentHash, currentPayload);
      final blockedObject = await ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      ).objectFile(blockedHash);
      await Directory(blockedObject.path).create(recursive: true);
      await index.touchTransient(
        'test@mail.ru',
        _transientRecord(blockedHash, 524288001, 1),
      );
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file('/current.txt', currentPayload.length, currentHash),
        ]),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      await repository.startOpen(_node('/current.txt')).result;

      expect(
        await index.hasTransientReference('test@mail.ru', blockedHash),
        isTrue,
      );
      expect(await Directory(blockedObject.path).exists(), isTrue);
    },
  );

  test(
    'reconciles only unreferenced canonical objects in the current account',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-reconcile',
      );
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      final index = _MemoryOfflineFileIndex();
      const directHash = '00112233445566778899AABBCCDDEEFF00112233';
      const targetHash = '11223344556677889900AABBCCDDEEFF11223344';
      const transientHash = '223344556677889900AABBCCDDEEFF1122334455';
      const sharedHash = '3344556677889900AABBCCDDEEFF112233445566';
      const orphanHash = 'AABBCCDDEEFF00112233445566778899AABBCCDD';
      const otherHash = 'FFEEDDCCBBAA99887766554433221100FFEEDDCC';
      const directoryHash = '44556677889900AABBCCDDEEFF11223344556677';
      const symlinkHash = '556677889900AABBCCDDEEFF1122334455667788';

      for (final hash in [
        directHash,
        targetHash,
        transientHash,
        sharedHash,
        orphanHash,
      ]) {
        await _writeObject(root, 'test@mail.ru', hash, const [1]);
      }
      await _writeObject(root, 'other@mail.ru', otherHash, const [2]);
      await index.upsert(
        'test@mail.ru',
        _offlineRecord('/old-direct.txt', directHash),
      );
      await index.upsert(
        'test@mail.ru',
        _offlineRecord('/shared-one.txt', sharedHash),
      );
      await index.upsert(
        'test@mail.ru',
        _offlineRecord('/shared-two.txt', sharedHash),
      );
      await index.upsertTarget('test@mail.ru', _targetRecord('/target'));
      await index.upsertTargetFile(
        'test@mail.ru',
        _targetFileRecord(
          '/target',
          '/target/file.txt',
          hash: targetHash,
          readiness: OfflineReadiness.ready,
        ),
      );
      await index.touchTransient(
        'test@mail.ru',
        _transientRecord(transientHash, 1, 1),
      );

      final cache = ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      );
      final orphan = await cache.objectFile(orphanHash);
      final part = await cache.partFile(orphanHash);
      await part.writeAsBytes(const [3]);
      await File('${orphan.path}.unknown').writeAsBytes(const [4]);
      await File(
        '${orphan.parent.path}${Platform.pathSeparator}malformed',
      ).writeAsBytes(const [5]);
      File? lowercase;
      if (!Platform.isWindows) {
        lowercase = File(
          '${orphan.parent.path}${Platform.pathSeparator}${orphanHash.toLowerCase()}',
        );
        await lowercase.writeAsBytes(const [7]);
      }
      final directoryObject = await cache.objectFile(directoryHash);
      await Directory(directoryObject.path).create(recursive: true);
      final symlinkObject = await cache.objectFile(symlinkHash);
      await symlinkObject.parent.create(recursive: true);
      final symlinkTarget = File(
        '${root.path}${Platform.pathSeparator}reconcile-outside',
      );
      await symlinkTarget.writeAsBytes(const [6]);
      var symlinkCreated = false;
      try {
        await Link(symlinkObject.path).create(symlinkTarget.path);
        symlinkCreated = true;
      } on FileSystemException {
        // Symlink creation can be disabled for a Windows test process.
      }

      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport(const []),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      expect(
        (await cache.enumerateFinalObjects()).map(
          (candidate) => candidate.hash,
        ),
        contains(orphanHash),
      );
      expect(await index.hasHashReference('test@mail.ru', orphanHash), isFalse);
      expect(
        await index.hasTransientReference('test@mail.ru', orphanHash),
        isFalse,
      );
      await repository.reconcileAccountCache(expectedEmail: ' TEST@MAIL.RU ');

      for (final hash in [directHash, targetHash, transientHash, sharedHash]) {
        expect(
          await FileSystemEntity.type(
            (await cache.objectFile(hash)).path,
            followLinks: false,
          ),
          FileSystemEntityType.file,
        );
      }
      expect(await orphan.exists(), isFalse);
      expect(await part.exists(), isTrue);
      expect(await File('${orphan.path}.unknown').exists(), isTrue);
      expect(
        await File(
          '${orphan.parent.path}${Platform.pathSeparator}malformed',
        ).exists(),
        isTrue,
      );
      expect(
        await FileSystemEntity.type(
          (await ContentAddressedFileCache(
            root: root,
            email: 'other@mail.ru',
          ).objectFile(otherHash)).path,
          followLinks: false,
        ),
        FileSystemEntityType.file,
      );
      if (symlinkCreated) {
        expect(
          await FileSystemEntity.type(symlinkObject.path, followLinks: false),
          FileSystemEntityType.link,
        );
      }
      if (lowercase != null) expect(await lowercase.exists(), isTrue);
    },
  );

  test('reconciliation waits for direct ownership publication', () async {
    final payload = utf8.encode('reconciliation waits for index');
    final hash = calculateCloudHash(payload);
    final root = await Directory.systemTemp.createTemp('easy-cloud-reconcile');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    final ownershipStarted = Completer<void>();
    final releaseOwnership = Completer<void>();
    final index = _MemoryOfflineFileIndex()
      ..upsertStarted = ownershipStarted
      ..upsertGate = () => releaseOwnership.future;
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport([_file('/race.txt', payload.length, hash)]),
      downloadTransport: _DownloadTransport(payload),
      index: index,
    );
    addTearDown(repository.close);

    final download = repository.start(_node('/race.txt'));
    await ownershipStarted.future;
    var reconciliationCompleted = false;
    final reconciliation = repository
        .reconcileAccountCache(expectedEmail: 'test@mail.ru')
        .then<void>((_) => reconciliationCompleted = true);
    await _settle();
    expect(reconciliationCompleted, isFalse);

    releaseOwnership.complete();
    await Future.wait([download.result, reconciliation]);

    final object = await ContentAddressedFileCache(
      root: root,
      email: 'test@mail.ru',
    ).objectFile(hash);
    expect(await object.exists(), isTrue);
    expect(await index.list('test@mail.ru'), hasLength(1));
  });

  test(
    'concurrent account reconciliations are serialized and idempotent',
    () async {
      const hash = 'AABBCCDDEEFF00112233445566778899AABBCCDD';
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-reconcile',
      );
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      await _writeObject(root, 'test@mail.ru', hash, const [1]);
      final referenceStarted = Completer<void>();
      final releaseReference = Completer<void>();
      final index = _MemoryOfflineFileIndex()
        ..hashReferenceStarted = referenceStarted
        ..hashReferenceGate = () => releaseReference.future;
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport(const []),
        downloadTransport: _DownloadTransport(const []),
        index: index,
      );
      addTearDown(repository.close);

      final first = repository.reconcileAccountCache(
        expectedEmail: 'test@mail.ru',
      );
      await referenceStarted.future;
      final second = repository.reconcileAccountCache(
        expectedEmail: 'test@mail.ru',
      );
      await _settle();
      expect(index.hasHashReferenceCalls, 1);

      releaseReference.complete();
      await Future.wait([first, second]);

      expect(
        await (await ContentAddressedFileCache(
          root: root,
          email: 'test@mail.ru',
        ).objectFile(hash)).exists(),
        isFalse,
      );
    },
  );

  test(
    'a download started under reconciliation is serialized safely',
    () async {
      final payload = utf8.encode('download follows reconciliation');
      final hash = calculateCloudHash(payload);
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-reconcile',
      );
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      await _writeObject(root, 'test@mail.ru', hash, payload);
      final referenceStarted = Completer<void>();
      final releaseReference = Completer<void>();
      final index = _MemoryOfflineFileIndex()
        ..hashReferenceStarted = referenceStarted
        ..hashReferenceGate = () => releaseReference.future;
      final downloadTransport = _DownloadTransport(payload);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport([
          _file('/race.txt', payload.length, hash),
        ]),
        downloadTransport: downloadTransport,
        index: index,
      );
      addTearDown(repository.close);

      final reconciliation = repository.reconcileAccountCache(
        expectedEmail: 'test@mail.ru',
      );
      await referenceStarted.future;
      final download = repository.start(_node('/race.txt'));
      await _settle();
      expect(downloadTransport.calls, 0);

      releaseReference.complete();
      await Future.wait([reconciliation, download.result]);

      expect(await index.list('test@mail.ru'), hasLength(1));
      expect(
        await (await ContentAddressedFileCache(
          root: root,
          email: 'test@mail.ru',
        ).objectFile(hash)).exists(),
        isTrue,
      );
    },
  );

  test('session switch cancels reconciliation before deletion', () async {
    const hash = 'AABBCCDDEEFF00112233445566778899AABBCCDD';
    final root = await Directory.systemTemp.createTemp('easy-cloud-reconcile');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    await _writeObject(root, 'test@mail.ru', hash, const [1]);
    final referenceStarted = Completer<void>();
    final releaseReference = Completer<void>();
    final index = _MemoryOfflineFileIndex()
      ..hashReferenceStarted = referenceStarted
      ..hashReferenceGate = () => releaseReference.future;
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport(const []),
      downloadTransport: _DownloadTransport(const []),
      index: index,
    );
    addTearDown(repository.close);

    final reconciliation = repository.reconcileAccountCache(
      expectedEmail: 'test@mail.ru',
    );
    await referenceStarted.future;
    final logout = auth.logout();
    releaseReference.complete();
    await logout;

    await expectLater(reconciliation, throwsA(isA<DownloadCancelled>()));
    expect(
      await (await ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      ).objectFile(hash)).exists(),
      isTrue,
    );
  });

  test('stale expected account is rejected before reconciliation', () async {
    const hash = 'AABBCCDDEEFF00112233445566778899AABBCCDD';
    final root = await Directory.systemTemp.createTemp('easy-cloud-reconcile');
    addTearDown(() => root.delete(recursive: true));
    final auth = await _authenticatedRepository();
    addTearDown(auth.close);
    await _writeObject(root, 'test@mail.ru', hash, const [1]);
    final repository = _repository(
      root: root,
      auth: auth,
      statTransport: _StatTransport(const []),
      downloadTransport: _DownloadTransport(const []),
    );
    addTearDown(repository.close);

    await expectLater(
      repository.reconcileAccountCache(expectedEmail: 'other@mail.ru'),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(
      await (await ContentAddressedFileCache(
        root: root,
        email: 'test@mail.ru',
      ).objectFile(hash)).exists(),
      isTrue,
    );
  });

  test(
    'close waits for reconciliation and prevents later database queries',
    () async {
      const hash = 'AABBCCDDEEFF00112233445566778899AABBCCDD';
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-reconcile',
      );
      addTearDown(() => root.delete(recursive: true));
      final auth = await _authenticatedRepository();
      addTearDown(auth.close);
      await _writeObject(root, 'test@mail.ru', hash, const [1]);
      final referenceStarted = Completer<void>();
      final releaseReference = Completer<void>();
      final index = _MemoryOfflineFileIndex()
        ..hashReferenceStarted = referenceStarted
        ..hashReferenceGate = () => releaseReference.future;
      final transport = _DownloadTransport(const []);
      final repository = _repository(
        root: root,
        auth: auth,
        statTransport: _StatTransport(const []),
        downloadTransport: transport,
        index: index,
      );

      final reconciliation = repository.reconcileAccountCache(
        expectedEmail: 'test@mail.ru',
      );
      await referenceStarted.future;
      final closing = repository.close();
      expect(transport.closed, isFalse);
      releaseReference.complete();

      await expectLater(reconciliation, throwsA(isA<DownloadCancelled>()));
      await closing;
      expect(transport.closed, isTrue);
      expect(index.hasTransientReferenceCalls, 0);
    },
  );
}

CloudDownloadRepository _repository({
  required Directory root,
  required AuthRepository auth,
  required _StatTransport statTransport,
  required _DownloadTransport downloadTransport,
  _MemoryOfflineFileIndex? index,
}) {
  final coordinator = CloudCacheCoordinator();
  addTearDown(coordinator.close);
  return CloudDownloadRepository(
    api: CloudMailApi(statTransport),
    transport: downloadTransport,
    authRepository: auth,
    offlineFileIndex: index ?? _MemoryOfflineFileIndex(),
    cacheRoot: root,
    coordinator: coordinator,
  );
}

final class _MemoryOfflineFileIndex
    implements OfflineTargetStorage, TransientObjectIndex {
  final records = <String, OfflineFileRecord>{};
  final targets = <String, OfflineTargetRecord>{};
  final targetFiles = <String, OfflineTargetFileRecord>{};
  final transientRecords = <String, TransientObjectRecord>{};
  final targetEvents = <String>[];
  int upsertCalls = 0;
  int removeCalls = 0;
  int targetReadyCalls = 0;
  Object? nextUpsertFailure;
  Object? nextTargetReadyFailure;
  Future<void> Function()? lookupGate;
  Future<void> Function()? removalGate;
  Future<void> Function()? targetLookupGate;
  Future<void> Function()? targetReadyGate;
  Future<void> Function()? targetRemovalGate;
  Future<void> Function()? transientRemovalGate;
  Future<void> Function()? upsertGate;
  Future<void> Function()? hashReferenceGate;
  Completer<void>? removalStarted;
  Completer<void>? targetReadyCompleted;
  Completer<void>? targetRemovalStarted;
  Completer<void>? transientRemovalStarted;
  Completer<void>? upsertStarted;
  Completer<void>? hashReferenceStarted;
  int? transientSizeOverride;
  int hasHashReferenceCalls = 0;
  int hasTransientReferenceCalls = 0;

  @override
  Future<void> upsert(String email, OfflineFileRecord record) async {
    upsertCalls++;
    final started = upsertStarted;
    if (started != null && !started.isCompleted) started.complete();
    await upsertGate?.call();
    final failure = nextUpsertFailure;
    nextUpsertFailure = null;
    if (failure != null) throw failure;
    records['${email.trim().toLowerCase()}:${record.path}'] = record;
    transientRecords.remove('${email.trim().toLowerCase()}:${record.hash}');
  }

  @override
  Future<List<OfflineFileRecord>> list(String email) async => records.entries
      .where((entry) => entry.key.startsWith('${email.trim().toLowerCase()}:'))
      .map((entry) => entry.value)
      .toList(growable: false);

  @override
  Future<Map<String, OfflineFileRecord>> lookup(
    String email,
    Iterable<String> paths,
  ) async {
    await lookupGate?.call();
    final account = email.trim().toLowerCase();
    final result = <String, OfflineFileRecord>{};
    for (final path in paths) {
      final record = records['$account:$path'];
      if (record != null) result[path] = record;
    }
    return result;
  }

  @override
  Future<bool> hasHashReference(String email, String hash) async {
    hasHashReferenceCalls++;
    final started = hashReferenceStarted;
    if (started != null && !started.isCompleted) started.complete();
    await hashReferenceGate?.call();
    final account = email.trim().toLowerCase();
    final normalizedHash = hash.trim().toUpperCase();
    if (records.entries
        .where((entry) => entry.key.startsWith('$account:'))
        .any((entry) => entry.value.hash == normalizedHash)) {
      return true;
    }
    return targetFiles.entries
        .where((entry) => entry.key.startsWith('$account:'))
        .any(
          (entry) =>
              entry.value.readiness == OfflineReadiness.ready &&
              entry.value.hash == normalizedHash,
        );
  }

  @override
  Future<void> touchTransient(
    String email,
    TransientObjectRecord record,
  ) async {
    final stored = transientSizeOverride == null
        ? record
        : TransientObjectRecord(
            hash: record.hash,
            size: transientSizeOverride!,
            lastAccessedAt: record.lastAccessedAt,
          );
    transientRecords['${email.trim().toLowerCase()}:${record.hash}'] = stored;
  }

  @override
  Future<List<TransientObjectRecord>> listTransient(String email) async {
    final account = email.trim().toLowerCase();
    final result = transientRecords.entries
        .where((entry) => entry.key.startsWith('$account:'))
        .map((entry) => entry.value)
        .toList();
    result.sort((left, right) {
      final byTime = left.lastAccessedAt.compareTo(right.lastAccessedAt);
      return byTime == 0 ? left.hash.compareTo(right.hash) : byTime;
    });
    return result;
  }

  @override
  Future<void> removeTransient(String email, String hash) async {
    targetEvents.add('removeTransient');
    final removalStarted = transientRemovalStarted;
    if (removalStarted != null && !removalStarted.isCompleted) {
      removalStarted.complete();
    }
    await transientRemovalGate?.call();
    transientRecords.remove(
      '${email.trim().toLowerCase()}:${hash.trim().toUpperCase()}',
    );
  }

  @override
  Future<bool> hasTransientReference(String email, String hash) =>
      _hasTransientReference(email, hash);

  Future<bool> _hasTransientReference(String email, String hash) async {
    hasTransientReferenceCalls++;
    return transientRecords.containsKey(
      '${email.trim().toLowerCase()}:${hash.trim().toUpperCase()}',
    );
  }

  @override
  Future<void> remove(String email, String path) async {
    removeCalls++;
    final started = removalStarted;
    if (started != null && !started.isCompleted) started.complete();
    await removalGate?.call();
    records.remove('${email.trim().toLowerCase()}:$path');
  }

  @override
  Future<void> clearAccount(String email) async {
    records.removeWhere(
      (key, _) => key.startsWith('${email.trim().toLowerCase()}:'),
    );
    targets.removeWhere(
      (key, _) => key.startsWith('${email.trim().toLowerCase()}:'),
    );
    targetFiles.removeWhere(
      (key, _) => key.startsWith('${email.trim().toLowerCase()}:'),
    );
    transientRecords.removeWhere(
      (key, _) => key.startsWith('${email.trim().toLowerCase()}:'),
    );
  }

  @override
  Future<void> upsertTarget(String email, OfflineTargetRecord target) async {
    targets[_targetKey(email, target.targetPath)] = target;
  }

  @override
  Future<OfflineTargetRecord?> getTarget(
    String email,
    String targetPath, {
    String? targetIncarnation,
  }) async {
    final target = targets[_targetKey(email, targetPath)];
    if (targetIncarnation != null &&
        target?.targetIncarnation != targetIncarnation) {
      return null;
    }
    return target;
  }

  @override
  Future<List<OfflineTargetRecord>> listTargets(String email) async => targets
      .entries
      .where((entry) => entry.key.startsWith('${email.trim().toLowerCase()}:'))
      .map((entry) => entry.value)
      .toList(growable: false);

  @override
  Future<void> upsertFrontier(
    String email,
    OfflineTargetFrontierRecord frontier,
  ) async => throw UnimplementedError();

  @override
  Future<List<OfflineTargetFrontierRecord>> listFrontier(
    String email,
    String targetPath, {
    String? targetIncarnation,
  }) async => throw UnimplementedError();

  @override
  Future<OfflineTargetFrontierRecord?> claimFrontier(
    String email,
    String targetPath, {
    required String targetIncarnation,
    String? folderPath,
  }) async => throw UnimplementedError();

  @override
  Future<void> updateFrontier(
    String email,
    OfflineTargetFrontierRecord frontier,
  ) async => throw UnimplementedError();

  @override
  Future<void> recoverInProgress(
    String email, {
    String? targetPath,
    String? targetIncarnation,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> upsertTargetFile(
    String email,
    OfflineTargetFileRecord file,
  ) async {
    targetFiles[_targetFileKey(email, file.targetPath, file.filePath)] = file;
  }

  @override
  Future<OfflineTargetFileRecord?> getTargetFile(
    String email,
    String targetPath,
    String filePath, {
    String? targetIncarnation,
  }) async {
    await targetLookupGate?.call();
    final target = targets[_targetKey(email, targetPath)];
    if (target == null ||
        (targetIncarnation != null &&
            target.targetIncarnation != targetIncarnation)) {
      return null;
    }
    final file = targetFiles[_targetFileKey(email, targetPath, filePath)];
    return file?.targetIncarnation == target.targetIncarnation ? file : null;
  }

  @override
  Future<OfflineTargetFileRecord?> lookupReadyTargetFile(
    String email,
    String filePath,
  ) async {
    await targetLookupGate?.call();
    final account = email.trim().toLowerCase();
    final normalizedPath = normalizeOfflineRemotePath(filePath);
    final candidates = targetFiles.entries
        .where((entry) => entry.key.startsWith('$account:'))
        .map((entry) => entry.value)
        .where((file) {
          final target = targets[_targetKey(account, file.targetPath)];
          return file.filePath == normalizedPath &&
              file.readiness == OfflineReadiness.ready &&
              file.size != null &&
              file.hash != null &&
              target != null &&
              target.state != OfflineTargetState.removing &&
              target.targetIncarnation == file.targetIncarnation;
        })
        .toList();
    candidates.sort((left, right) {
      final bySpecificity = right.targetPath.length.compareTo(
        left.targetPath.length,
      );
      if (bySpecificity != 0) return bySpecificity;
      final byPath = left.targetPath.compareTo(right.targetPath);
      if (byPath != 0) return byPath;
      return left.targetIncarnation.compareTo(right.targetIncarnation);
    });
    return candidates.isEmpty ? null : candidates.first;
  }

  @override
  Future<bool> markTargetFileReady(
    String email, {
    required String targetPath,
    required String filePath,
    required String targetIncarnation,
    required String hash,
    required int size,
    DateTime? modifiedAt,
    String? revision,
    String? globalRevision,
  }) async {
    targetReadyCalls++;
    targetEvents.add('markTargetFileReady');
    final readyStarted = targetReadyCompleted;
    if (readyStarted != null && !readyStarted.isCompleted) {
      readyStarted.complete();
    }
    await targetReadyGate?.call();
    final failure = nextTargetReadyFailure;
    nextTargetReadyFailure = null;
    if (failure != null) throw failure;
    final key = _targetFileKey(email, targetPath, filePath);
    final current = targetFiles[key];
    if (targets[_targetKey(email, targetPath)]?.targetIncarnation !=
            targetIncarnation ||
        current == null ||
        current.targetIncarnation != targetIncarnation) {
      return false;
    }
    targetFiles[key] = OfflineTargetFileRecord(
      targetPath: current.targetPath,
      targetIncarnation: current.targetIncarnation,
      filePath: current.filePath,
      name: current.name,
      hash: hash,
      size: size,
      modifiedAt: modifiedAt,
      revision: revision,
      globalRevision: globalRevision,
      readiness: OfflineReadiness.ready,
      bytesDone: size,
      errorCode: null,
      lastSeenScanId: current.lastSeenScanId,
      updatedAt: DateTime.now().toUtc(),
    );
    targetEvents.add('targetReady');
    return true;
  }

  @override
  Future<List<OfflineTargetFileRecord>> listTargetFiles(
    String email,
    String targetPath, {
    String? targetIncarnation,
  }) async => targetFiles.entries
      .where(
        (entry) =>
            entry.key.startsWith('${email.trim().toLowerCase()}:') &&
            entry.value.targetPath == normalizeOfflineRemotePath(targetPath) &&
            (targetIncarnation == null ||
                entry.value.targetIncarnation == targetIncarnation),
      )
      .map((entry) => entry.value)
      .toList(growable: false);

  @override
  Future<void> updateTargetFileReadiness(
    String email, {
    required String targetPath,
    required String filePath,
    required String targetIncarnation,
    required OfflineReadiness readiness,
    int? bytesDone,
    int? total,
    String? errorCode,
  }) async {
    final key = _targetFileKey(email, targetPath, filePath);
    final current = targetFiles[key];
    if (current == null || current.targetIncarnation != targetIncarnation) {
      throw StateError('Missing target membership.');
    }
    final authoritativeSize = total != null && total >= 0
        ? total
        : current.size;
    final requestedBytes = bytesDone ?? current.bytesDone;
    if (requestedBytes < 0) {
      throw ArgumentError.value(requestedBytes, 'bytesDone');
    }
    targetFiles[key] = OfflineTargetFileRecord(
      targetPath: current.targetPath,
      targetIncarnation: current.targetIncarnation,
      filePath: current.filePath,
      name: current.name,
      hash: current.hash,
      size: authoritativeSize,
      modifiedAt: current.modifiedAt,
      revision: current.revision,
      globalRevision: current.globalRevision,
      readiness: readiness,
      bytesDone: authoritativeSize != null && requestedBytes > authoritativeSize
          ? authoritativeSize
          : requestedBytes,
      errorCode: errorCode,
      lastSeenScanId: current.lastSeenScanId,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<OfflineTargetRemovalResult> removeTarget(
    String email,
    String targetPath, {
    required String targetIncarnation,
  }) async {
    final started = targetRemovalStarted;
    if (started != null && !started.isCompleted) started.complete();
    await targetRemovalGate?.call();
    final normalizedTargetPath = normalizeOfflineRemotePath(targetPath);
    final targetKey = _targetKey(email, normalizedTargetPath);
    final current = targets[targetKey];
    if (current?.targetIncarnation != targetIncarnation) {
      return OfflineTargetRemovalResult(
        target: null,
        removedFiles: const [],
        releasedHashes: const [],
        remainingReferences: const {},
      );
    }
    final target = targets.remove(targetKey);
    final removedFiles = targetFiles.entries
        .where(
          (entry) =>
              entry.key.startsWith('${email.trim().toLowerCase()}:') &&
              entry.value.targetPath == normalizedTargetPath &&
              entry.value.targetIncarnation == targetIncarnation,
        )
        .map((entry) => entry.value)
        .toList(growable: false);
    targetFiles.removeWhere(
      (key, file) =>
          key.startsWith('${email.trim().toLowerCase()}:') &&
          file.targetPath == normalizedTargetPath &&
          file.targetIncarnation == targetIncarnation,
    );
    return OfflineTargetRemovalResult(
      target: target,
      removedFiles: removedFiles,
      releasedHashes: {
        for (final file in removedFiles)
          if (file.hash != null) file.hash!,
      },
      remainingReferences: const {},
    );
  }

  @override
  Future<bool> hasHashReferenceOutsideTarget(
    String email,
    String hash, {
    required String targetPath,
    required String targetIncarnation,
  }) async {
    final account = email.trim().toLowerCase();
    final normalizedHash = hash.trim().toUpperCase();
    if (records.entries
        .where((entry) => entry.key.startsWith('$account:'))
        .any((entry) => entry.value.hash == normalizedHash)) {
      return true;
    }
    return targetFiles.entries
        .where((entry) => entry.key.startsWith('$account:'))
        .any(
          (entry) =>
              entry.value.targetIncarnation != targetIncarnation &&
              entry.value.readiness == OfflineReadiness.ready &&
              entry.value.hash == normalizedHash,
        );
  }

  @override
  Future<Map<String, OfflineAvailabilityState>> lookupEffectiveAvailability(
    String email,
    Iterable<String> paths,
  ) async => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

String _targetKey(String email, String targetPath) =>
    '${email.trim().toLowerCase()}:${normalizeOfflineRemotePath(targetPath)}';

String _targetFileKey(String email, String targetPath, String filePath) =>
    '${_targetKey(email, targetPath)}:${normalizeOfflineRemotePath(filePath)}';

CloudNode _node(String path) => CloudNode(
  path: path,
  name: path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.file,
);

CloudNode _file(
  String path,
  int size,
  String hash, {
  String? name,
  DateTime? modifiedAt,
  String? revision,
  String? globalRevision,
}) => CloudNode(
  path: path,
  name: name ?? path.substring(path.lastIndexOf('/') + 1),
  type: CloudNodeType.file,
  size: size,
  modifiedAt: modifiedAt,
  hash: hash,
  revision: revision,
  globalRevision: globalRevision,
);

OfflineFileRecord _offlineRecord(String path, String hash, {int size = 1}) =>
    OfflineFileRecord(
      path: path,
      name: path.substring(path.lastIndexOf('/') + 1),
      hash: hash,
      size: size,
      cachedAt: DateTime.now().toUtc(),
    );

OfflineTargetRecord _targetRecord(
  String path, {
  OfflineTargetState state = OfflineTargetState.queued,
}) {
  final normalizedPath = normalizeOfflineRemotePath(path);
  final now = DateTime.utc(2025, 1, 1);
  return OfflineTargetRecord(
    targetPath: normalizedPath,
    targetIncarnation: 'test-incarnation',
    targetName: normalizedPath == '/'
        ? 'root'
        : normalizedPath.substring(normalizedPath.lastIndexOf('/') + 1),
    state: state,
    scanComplete: false,
    estimateHasUnknown: true,
    createdAt: now,
    updatedAt: now,
  );
}

OfflineTargetFileRecord _targetFileRecord(
  String targetPath,
  String filePath, {
  String? name,
  String? hash,
  int? size,
  OfflineReadiness readiness = OfflineReadiness.queued,
}) => OfflineTargetFileRecord(
  targetPath: targetPath,
  targetIncarnation: 'test-incarnation',
  filePath: filePath,
  name: name ?? filePath.substring(filePath.lastIndexOf('/') + 1),
  hash: hash,
  size: size,
  readiness: readiness,
  bytesDone: readiness == OfflineReadiness.ready && size != null ? size : 0,
  updatedAt: DateTime.utc(2025, 1, 1),
);

TransientObjectRecord _transientRecord(String hash, int size, int seconds) =>
    TransientObjectRecord(
      hash: hash,
      size: size,
      lastAccessedAt: DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000,
        isUtc: true,
      ),
    );

Future<void> _writeObject(
  Directory root,
  String email,
  String hash,
  List<int> bytes,
) async {
  final cache = ContentAddressedFileCache(root: root, email: email);
  final object = await cache.objectFile(hash);
  await object.parent.create(recursive: true);
  await object.writeAsBytes(bytes);
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<AuthRepository> _authenticatedRepository({
  String email = 'test@mail.ru',
}) async {
  final store = MemorySessionStore()..session = _session(email: email);
  final repository = AuthRepository(api: _AuthApi(), store: store);
  await repository.restore();
  return repository;
}

CloudSession _session({String email = 'test@mail.ru'}) => CloudSession(
  email: email,
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
  }) async => _session(email: email);

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
    final body = <String, Object?>{
      'home': node.path,
      'name': node.name,
      'type': 'file',
      'size': node.size,
      'hash': node.hash,
    };
    if (node.modifiedAt != null) {
      body['mtime'] = node.modifiedAt!.toUtc().millisecondsSinceEpoch ~/ 1000;
    }
    if (node.revision != null) body['rev'] = node.revision;
    if (node.globalRevision != null) body['grev'] = node.globalRevision;
    return CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(jsonEncode({'status': 200, 'body': body})),
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
