import 'dart:io';

import 'package:easy_cloud/features/offline/application/offline_target_index.dart';
import 'package:easy_cloud/features/offline/data/sqlite_offline_file_index.dart';
import 'package:easy_cloud/features/offline/domain/offline_file_record.dart';
import 'package:easy_cloud/features/offline/domain/offline_target.dart';
import 'package:easy_cloud/features/offline/domain/transient_object_record.dart';
import 'package:easy_cloud/local/cache/application_cache_root.dart';
import 'package:easy_cloud/local/cache/content_addressed_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('creates v6 target tables and keeps account keys private', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-target');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });

    await index.upsertTarget(' User@Mail.RU ', _target('/photos/'));
    await index.upsertFrontier(
      'user@mail.ru',
      _frontier('/photos', '/photos', sequence: 0),
    );
    await index.upsertTargetFile(
      'user@mail.ru',
      _targetFile(
        '/photos',
        '/photos/cat.jpg',
        readiness: OfflineReadiness.queued,
      ),
    );

    final target = await index.getTarget('USER@MAIL.RU', 'photos/');
    expect(target?.targetPath, '/photos');
    expect(
      (await index.listFrontier('user@mail.ru', '/photos')).single.sequence,
      0,
    );
    expect(
      (await index.listTargetFiles('user@mail.ru', '/photos')).single.filePath,
      '/photos/cat.jpg',
    );

    await index.close();
    final database = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'cloud_cache', SqliteOfflineFileIndex.databaseFileName),
    );
    addTearDown(database.close);
    expect(await database.rawQuery('PRAGMA user_version'), [
      {'user_version': SqliteOfflineFileIndex.schemaVersion},
    ]);
    for (final table in [
      SqliteOfflineFileIndex.targetsTableName,
      SqliteOfflineFileIndex.targetFrontierTableName,
      SqliteOfflineFileIndex.targetFilesTableName,
    ]) {
      final rows = await database.query(table);
      expect(rows.single['account_key'], accountCacheKey('user@mail.ru'));
      expect(rows.single.values, isNot(contains('user@mail.ru')));
    }
  });

  test(
    'claims frontier deterministically and recovers interrupted work',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      final index = _index(root);
      addTearDown(() async {
        await index.close();
        await root.delete(recursive: true);
      });

      await index.upsertTarget('user@mail.ru', _target('/root'));
      await index.upsertFrontier(
        'user@mail.ru',
        _frontier('/root', '/root/second', sequence: 2),
      );
      await index.upsertFrontier(
        'user@mail.ru',
        _frontier('/root', '/root/first', sequence: 1),
      );
      final claimed = await index.claimFrontier(
        'user@mail.ru',
        '/root',
        targetIncarnation: 'test-incarnation',
      );
      expect(claimed?.folderPath, '/root/first');
      expect(claimed?.state, OfflineTargetFrontierState.scanning);

      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile(
          '/root',
          '/root/file.txt',
          readiness: OfflineReadiness.downloading,
        ),
      );
      await index.upsertTarget(
        'user@mail.ru',
        _target('/root', state: OfflineTargetState.running),
      );
      await index.recoverInProgress('user@mail.ru');

      expect(
        (await index.getTarget('user@mail.ru', '/root'))?.state,
        OfflineTargetState.queued,
      );
      expect(
        (await index.listFrontier('user@mail.ru', '/root')).first.state,
        OfflineTargetFrontierState.pending,
      );
      expect(
        (await index.listTargetFiles('user@mail.ru', '/root')).single.readiness,
        OfflineReadiness.queued,
      );
    },
  );

  test('recovery preserves a durable removing intent', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-target');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });

    await index.upsertTarget('user@mail.ru', _target('/removing'));
    await index.upsertFrontier(
      'user@mail.ru',
      _frontier('/removing', '/removing', sequence: 0),
    );
    await index.upsertTargetFile(
      'user@mail.ru',
      _targetFile(
        '/removing',
        '/removing/file.txt',
        readiness: OfflineReadiness.downloading,
      ),
    );
    await index.updateTarget(
      'user@mail.ru',
      _target('/removing', state: OfflineTargetState.removing),
    );

    await index.recoverInProgress('user@mail.ru');

    expect(
      (await index.getTarget('user@mail.ru', '/removing'))?.state,
      OfflineTargetState.removing,
    );
    expect(
      (await index.listTargetFiles(
        'user@mail.ru',
        '/removing',
      )).single.readiness,
      OfflineReadiness.queued,
    );
  });

  test('incarnation-scoped recovery cannot reset a newer target', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-target');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });

    await index.upsertTarget(
      'user@mail.ru',
      _target(
        '/same',
        incarnation: 'new-incarnation',
        state: OfflineTargetState.running,
        scanComplete: true,
      ),
    );
    await index.upsertFrontier(
      'user@mail.ru',
      _frontier(
        '/same',
        '/same',
        sequence: 0,
        incarnation: 'new-incarnation',
        state: OfflineTargetFrontierState.scanning,
      ),
    );

    await index.recoverInProgress(
      'user@mail.ru',
      targetPath: '/same',
      targetIncarnation: 'old-incarnation',
    );

    expect(
      (await index.getTarget('user@mail.ru', '/same'))?.state,
      OfflineTargetState.running,
    );
    expect(
      (await index.listFrontier('user@mail.ru', '/same')).single.state,
      OfflineTargetFrontierState.scanning,
    );
  });

  test(
    'stale incarnation operations cannot touch a re-enqueued path',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      final index = _index(root);
      addTearDown(() async {
        await index.close();
        await root.delete(recursive: true);
      });
      const oldIncarnation = 'old-incarnation';
      const newIncarnation = 'new-incarnation';
      const hash = '00112233445566778899AABBCCDDEEFF00112233';

      await index.upsertTarget(
        'user@mail.ru',
        _target('/same', incarnation: oldIncarnation),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile(
          '/same',
          '/same/file.txt',
          incarnation: oldIncarnation,
          readiness: OfflineReadiness.queued,
        ),
      );
      await index.removeTarget(
        'user@mail.ru',
        '/same',
        targetIncarnation: oldIncarnation,
      );
      await index.createTargetWithRootIfNoOverlap(
        'user@mail.ru',
        _target('/same', incarnation: newIncarnation),
        _frontier('/same', '/same', sequence: 0, incarnation: newIncarnation),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile(
          '/same',
          '/same/file.txt',
          incarnation: newIncarnation,
          readiness: OfflineReadiness.queued,
        ),
      );

      expect(
        await index.markTargetFileReady(
          'user@mail.ru',
          targetPath: '/same',
          filePath: '/same/file.txt',
          targetIncarnation: oldIncarnation,
          hash: hash,
          size: 1,
        ),
        isFalse,
      );
      final staleRemoval = await index.removeTarget(
        'user@mail.ru',
        '/same',
        targetIncarnation: oldIncarnation,
      );
      expect(staleRemoval.removed, isFalse);
      expect(
        (await index.getTarget('user@mail.ru', '/same'))?.targetIncarnation,
        newIncarnation,
      );
    },
  );

  test(
    'concurrent overlapping enqueues have one transactional winner',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      final first = _index(root);
      final second = _index(root);
      addTearDown(() async {
        await first.close();
        await second.close();
        await root.delete(recursive: true);
      });
      final targetA = _target('/parent', incarnation: 'inc-a');
      final targetB = _target('/parent/child', incarnation: 'inc-b');
      final rootA = _frontier(
        '/parent',
        '/parent',
        sequence: 0,
        incarnation: 'inc-a',
      );
      final rootB = _frontier(
        '/parent/child',
        '/parent/child',
        sequence: 0,
        incarnation: 'inc-b',
      );
      final results = await Future.wait<Object?>([
        first
            .createTargetWithRootIfNoOverlap('user@mail.ru', targetA, rootA)
            .then<Object?>((_) => null, onError: (Object error) => error),
        second
            .createTargetWithRootIfNoOverlap('user@mail.ru', targetB, rootB)
            .then<Object?>((_) => null, onError: (Object error) => error),
      ]);
      expect(results.whereType<OfflineTargetOverlapException>(), hasLength(1));
      expect((await first.listTargets('user@mail.ru')), hasLength(1));
    },
  );

  test(
    'effective availability is account-isolated, overlap-safe, and prioritized',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      final index = _index(root);
      addTearDown(() async {
        await index.close();
        await root.delete(recursive: true);
      });
      final hash = '00112233445566778899AABBCCDDEEFF00112233';

      await index.upsertTarget(
        'user@mail.ru',
        _target('/a', state: OfflineTargetState.queued),
      );
      await index.upsertTarget(
        'user@mail.ru',
        _target('/a/b', state: OfflineTargetState.ready, scanComplete: true),
      );
      await index.upsertTarget(
        'other@mail.ru',
        _target('/a', state: OfflineTargetState.ready, scanComplete: true),
      );
      await index.upsertTarget(
        'user@mail.ru',
        _target('/ready', state: OfflineTargetState.ready, scanComplete: true),
      );
      await index.upsertFrontier(
        'user@mail.ru',
        _frontier(
          '/ready',
          '/ready',
          sequence: 0,
          state: OfflineTargetFrontierState.complete,
        ),
      );
      await index.upsertFrontier(
        'user@mail.ru',
        _frontier(
          '/ready',
          '/ready/known-folder',
          sequence: 1,
          state: OfflineTargetFrontierState.complete,
        ),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/ready', '/ready/known-folder/file.txt', hash: hash),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/a', '/a/file.txt', readiness: OfflineReadiness.queued),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/a/b', '/a/b/file.txt', hash: hash),
      );
      await index.upsert(
        'user@mail.ru',
        OfflineFileRecord(
          path: '/a/b/file.txt',
          name: 'direct.txt',
          hash: hash,
          size: 1,
          cachedAt: DateTime.utc(2025),
        ),
      );

      final states = await index.lookupEffectiveAvailability('user@mail.ru', [
        '/a',
        '/a/b',
        '/a/b/file.txt',
        '/a/file.txt',
        '/ab/file.txt',
        '/ready',
        '/ready/known-folder',
        '/ready/known-folder/file.txt',
        '/ready/unknown-child',
      ]);
      expect(states['/a']?.source, OfflineAvailabilitySource.directTarget);
      expect(states['/a']?.readiness, OfflineReadiness.queued);
      expect(states['/a/b']?.source, OfflineAvailabilitySource.directTarget);
      expect(states['/a/b']?.readiness, OfflineReadiness.ready);
      expect(states['/a/b/file.txt']?.source, OfflineAvailabilitySource.direct);
      expect(states['/a/b/file.txt']?.readiness, OfflineReadiness.ready);
      expect(states['/a/file.txt']?.readiness, OfflineReadiness.queued);
      expect(
        states['/ab/file.txt']?.source,
        OfflineAvailabilitySource.onlineOnly,
      );
      expect(states['/ab/file.txt']?.readiness, OfflineReadiness.idle);
      expect(states['/ready']?.source, OfflineAvailabilitySource.directTarget);
      expect(states['/ready']?.readiness, OfflineReadiness.ready);
      expect(
        states['/ready/known-folder']?.source,
        OfflineAvailabilitySource.inherited,
      );
      expect(states['/ready/known-folder']?.readiness, OfflineReadiness.ready);
      expect(
        states['/ready/known-folder/file.txt']?.readiness,
        OfflineReadiness.ready,
      );
      expect(
        states['/ready/unknown-child']?.source,
        OfflineAvailabilitySource.onlineOnly,
      );
      expect(states['/ready/unknown-child']?.readiness, OfflineReadiness.idle);

      expect(
        await index
            .lookupEffectiveAvailability('other@mail.ru', ['/a/file.txt'])
            .then((result) => result['/a/file.txt']?.readiness),
        OfflineReadiness.idle,
      );
    },
  );

  test(
    'target hash references require ready valid membership and remove one target only',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      final index = _index(root);
      addTearDown(() async {
        await index.close();
        await root.delete(recursive: true);
      });
      const hash = '00112233445566778899AABBCCDDEEFF00112233';

      await index.upsertTarget('user@mail.ru', _target('/one'));
      await index.upsertTarget('user@mail.ru', _target('/two'));
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
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/one', '/one/file.txt', hash: hash),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/two', '/two/file.txt', hash: hash),
      );
      expect(await index.hasHashReference('user@mail.ru', hash), isTrue);
      await index.touchTransient(
        'user@mail.ru',
        TransientObjectRecord(
          hash: hash,
          size: 1,
          lastAccessedAt: DateTime.utc(2025),
        ),
      );

      final removed = await index.removeTarget(
        'user@mail.ru',
        '/one',
        targetIncarnation: 'test-incarnation',
      );
      expect(removed.removed, isTrue);
      expect(removed.releasedHashes, contains(hash));
      expect(await index.getTarget('user@mail.ru', '/one'), isNull);
      expect(await index.listTargetFiles('user@mail.ru', '/two'), hasLength(1));
      expect(await index.list('user@mail.ru'), hasLength(1));
      expect(await index.hasHashReference('user@mail.ru', hash), isTrue);
      expect(await index.hasTransientReference('user@mail.ru', hash), isTrue);

      await index.removeTarget(
        'user@mail.ru',
        '/two',
        targetIncarnation: 'test-incarnation',
      );
      expect(await index.hasHashReference('user@mail.ru', hash), isTrue);
      await index.remove('user@mail.ru', '/direct.txt');
      expect(await index.hasHashReference('user@mail.ru', hash), isFalse);
    },
  );

  test('finalizes only an existing target membership atomically', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-target');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });
    const hash = '00112233445566778899AABBCCDDEEFF00112233';
    final modifiedAt = DateTime.utc(2025, 5, 6);

    await index.upsertTarget('user@mail.ru', _target('/target'));
    await index.upsertTargetFile(
      'user@mail.ru',
      _targetFile(
        '/target',
        '/target/file.txt',
        readiness: OfflineReadiness.queued,
      ),
    );
    expect(
      (await index.getTargetFile(
        'user@mail.ru',
        '/target/',
        '/target/file.txt',
      ))?.readiness,
      OfflineReadiness.queued,
    );

    expect(
      await index.markTargetFileReady(
        'user@mail.ru',
        targetPath: '/target',
        filePath: '/target/file.txt',
        targetIncarnation: 'test-incarnation',
        hash: hash.toLowerCase(),
        size: 42,
        modifiedAt: modifiedAt,
        revision: 'rev-2',
        globalRevision: 'grev-2',
      ),
      isTrue,
    );
    final ready = await index.getTargetFile(
      'user@mail.ru',
      '/target',
      '/target/file.txt',
    );
    expect(ready?.targetPath, '/target');
    expect(ready?.filePath, '/target/file.txt');
    expect(ready?.name, 'file.txt');
    expect(ready?.hash, hash);
    expect(ready?.size, 42);
    expect(ready?.modifiedAt, modifiedAt);
    expect(ready?.revision, 'rev-2');
    expect(ready?.globalRevision, 'grev-2');
    expect(ready?.readiness, OfflineReadiness.ready);
    expect(ready?.bytesDone, 42);

    await index.removeTarget(
      'user@mail.ru',
      '/target',
      targetIncarnation: 'test-incarnation',
    );
    expect(
      await index.markTargetFileReady(
        'user@mail.ru',
        targetPath: '/target',
        filePath: '/target/file.txt',
        targetIncarnation: 'test-incarnation',
        hash: hash,
        size: 42,
      ),
      isFalse,
    );
  });

  test(
    'lookupReadyTargetFile chooses the most specific live membership',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      final index = _index(root);
      addTearDown(() async {
        await index.close();
        await root.delete(recursive: true);
      });
      const hash = '00112233445566778899AABBCCDDEEFF00112233';

      await index.upsertTarget(
        'user@mail.ru',
        _target('/root', state: OfflineTargetState.ready),
      );
      await index.upsertTarget(
        'user@mail.ru',
        _target('/root/child', state: OfflineTargetState.ready),
      );
      await index.upsertTarget(
        'user@mail.ru',
        _target('/removed', state: OfflineTargetState.ready),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/root', '/root/child/file.txt', hash: hash),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/root/child', '/root/child/file.txt', hash: hash),
      );
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile('/removed', '/removed/file.txt', hash: hash),
      );
      await index.upsertTarget(
        'other@mail.ru',
        _target('/root/child', state: OfflineTargetState.ready),
      );
      await index.upsertTargetFile(
        'other@mail.ru',
        _targetFile('/root/child', '/root/child/file.txt', hash: hash),
      );
      await index.updateTarget(
        'user@mail.ru',
        _target('/removed', state: OfflineTargetState.removing),
      );

      final selected = await index.lookupReadyTargetFile(
        'USER@MAIL.RU',
        '/root/child/file.txt',
      );
      expect(selected?.targetPath, '/root/child');
      expect(selected?.targetIncarnation, 'test-incarnation');

      await index.updateTarget(
        'user@mail.ru',
        _target('/root/child', state: OfflineTargetState.removing),
      );
      final fallback = await index.lookupReadyTargetFile(
        'user@mail.ru',
        '/root/child/file.txt',
      );
      expect(fallback?.targetPath, '/root');
      expect(
        await index.lookupReadyTargetFile('user@mail.ru', '/missing.txt'),
        isNull,
      );
    },
  );

  test(
    'progress stores the authoritative total before clamping bytes',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      final index = _index(root);
      addTearDown(() async {
        await index.close();
        await root.delete(recursive: true);
      });
      const hash = '00112233445566778899AABBCCDDEEFF00112233';

      await index.upsertTarget('user@mail.ru', _target('/progress'));
      await index.upsertTargetFile(
        'user@mail.ru',
        _targetFile(
          '/progress',
          '/progress/file.txt',
          hash: hash,
          size: 10,
          readiness: OfflineReadiness.downloading,
        ),
      );

      await index.updateTargetFileReadiness(
        'user@mail.ru',
        targetPath: '/progress',
        filePath: '/progress/file.txt',
        targetIncarnation: 'test-incarnation',
        readiness: OfflineReadiness.downloading,
        bytesDone: 17,
        total: 20,
      );
      var file = await index.getTargetFile(
        'user@mail.ru',
        '/progress',
        '/progress/file.txt',
      );
      expect(file?.size, 20);
      expect(file?.bytesDone, 17);

      await index.updateTargetFileReadiness(
        'user@mail.ru',
        targetPath: '/progress',
        filePath: '/progress/file.txt',
        targetIncarnation: 'test-incarnation',
        readiness: OfflineReadiness.verifying,
        bytesDone: 25,
        total: 20,
      );
      file = await index.getTargetFile(
        'user@mail.ru',
        '/progress',
        '/progress/file.txt',
      );
      expect(file?.size, 20);
      expect(file?.bytesDone, 20);

      await index.updateTargetFileReadiness(
        'user@mail.ru',
        targetPath: '/progress',
        filePath: '/progress/file.txt',
        targetIncarnation: 'test-incarnation',
        readiness: OfflineReadiness.downloading,
        bytesDone: 9,
        total: 8,
      );
      file = await index.getTargetFile(
        'user@mail.ru',
        '/progress',
        '/progress/file.txt',
      );
      expect(file?.size, 8);
      expect(file?.bytesDone, 8);

      await index.updateTargetFileReadiness(
        'user@mail.ru',
        targetPath: '/progress',
        filePath: '/progress/file.txt',
        targetIncarnation: 'test-incarnation',
        readiness: OfflineReadiness.downloading,
        bytesDone: 25,
        total: -1,
      );
      file = await index.getTargetFile(
        'user@mail.ru',
        '/progress',
        '/progress/file.txt',
      );
      expect(file?.size, 8);
      expect(file?.bytesDone, 8);
    },
  );

  test('v4 migration is additive for direct rows and snapshot rows', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-target');
    final directory = Directory(p.join(root.path, 'cloud_cache'));
    await directory.create(recursive: true);
    final database = await databaseFactoryFfi.openDatabase(
      p.join(directory.path, SqliteOfflineFileIndex.databaseFileName),
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE offline_files (
              account_key TEXT NOT NULL,
              path TEXT NOT NULL,
              name TEXT NOT NULL,
              hash TEXT NOT NULL,
              size INTEGER NOT NULL,
              modified_at INTEGER,
              revision TEXT,
              global_revision TEXT,
              cached_at INTEGER NOT NULL,
              PRIMARY KEY (account_key, path)
            )
          ''');
          await db.execute('''
            CREATE TABLE cloud_folder_snapshot_generations (
              generation_id INTEGER PRIMARY KEY AUTOINCREMENT,
              account_key TEXT NOT NULL,
              folder_path TEXT NOT NULL,
              folder_name TEXT NOT NULL,
              folder_type INTEGER NOT NULL,
              folder_kind TEXT,
              folder_size INTEGER,
              folder_modified_at INTEGER,
              folder_hash TEXT,
              folder_revision TEXT,
              folder_global_revision TEXT,
              folder_tree TEXT,
              folder_web_link TEXT,
              folder_virus_scan TEXT,
              folder_file_count INTEGER,
              folder_folder_count INTEGER,
              expected_count INTEGER NOT NULL,
              next_offset INTEGER NOT NULL,
              page_limit INTEGER NOT NULL,
              fetched_at INTEGER NOT NULL,
              complete INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE cloud_folder_snapshot_heads (
              account_key TEXT NOT NULL,
              folder_path TEXT NOT NULL,
              generation_id INTEGER NOT NULL,
              PRIMARY KEY (account_key, folder_path)
            )
          ''');
          await db.execute('''
            CREATE TABLE cloud_folder_snapshot_children (
              generation_id INTEGER NOT NULL,
              account_key TEXT NOT NULL,
              folder_path TEXT NOT NULL,
              child_path TEXT NOT NULL,
              child_name TEXT NOT NULL,
              child_type INTEGER NOT NULL,
              child_kind TEXT,
              child_size INTEGER,
              child_modified_at INTEGER,
              child_hash TEXT,
              child_revision TEXT,
              child_global_revision TEXT,
              child_tree TEXT,
              child_web_link TEXT,
              child_virus_scan TEXT,
              child_file_count INTEGER,
              child_folder_count INTEGER,
              PRIMARY KEY (generation_id, child_path)
            )
          ''');
          await db.execute('''
            CREATE TABLE transient_objects (
              account_key TEXT NOT NULL,
              hash TEXT NOT NULL,
              size INTEGER NOT NULL,
              last_accessed_at INTEGER NOT NULL,
              PRIMARY KEY (account_key, hash)
            )
          ''');
          final account = accountCacheKey('legacy@mail.ru');
          await db.insert('offline_files', {
            'account_key': account,
            'path': '/legacy.txt',
            'name': 'legacy.txt',
            'hash': '00112233445566778899AABBCCDDEEFF00112233',
            'size': 1,
            'cached_at': 1000,
          });
          final generation = await db
              .insert('cloud_folder_snapshot_generations', {
                'account_key': account,
                'folder_path': '/',
                'folder_name': 'root',
                'folder_type': 1,
                'expected_count': 0,
                'next_offset': 0,
                'page_limit': 100,
                'fetched_at': 1000,
                'complete': 1,
              });
          await db.insert('cloud_folder_snapshot_heads', {
            'account_key': account,
            'folder_path': '/',
            'generation_id': generation,
          });
        },
      ),
    );
    await database.close();

    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });
    expect((await index.list('legacy@mail.ru')).single.path, '/legacy.txt');
    expect((await index.getTarget('legacy@mail.ru', '/missing')), isNull);

    final migrated = await databaseFactoryFfi.openDatabase(
      p.join(directory.path, SqliteOfflineFileIndex.databaseFileName),
    );
    addTearDown(migrated.close);
    expect(await migrated.rawQuery('PRAGMA user_version'), [
      {'user_version': SqliteOfflineFileIndex.schemaVersion},
    ]);
    expect(
      (await migrated.rawQuery(
        'SELECT COUNT(*) AS count FROM cloud_folder_snapshot_generations',
      )).single['count'],
      1,
    );
    expect(
      await migrated.rawQuery(
        'SELECT name FROM sqlite_master WHERE type = ? AND name IN (?, ?, ?)',
        [
          'table',
          SqliteOfflineFileIndex.targetsTableName,
          SqliteOfflineFileIndex.targetFrontierTableName,
          SqliteOfflineFileIndex.targetFilesTableName,
        ],
      ),
      hasLength(3),
    );
  });

  test(
    'v5 migration assigns incarnations and preserves lower-case hashes',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-target');
      final directory = Directory(p.join(root.path, 'cloud_cache'));
      await directory.create(recursive: true);
      final database = await databaseFactoryFfi.openDatabase(
        p.join(directory.path, SqliteOfflineFileIndex.databaseFileName),
        options: OpenDatabaseOptions(
          version: 5,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE offline_files (
              account_key TEXT NOT NULL,
              path TEXT NOT NULL,
              name TEXT NOT NULL,
              hash TEXT NOT NULL,
              size INTEGER NOT NULL,
              modified_at INTEGER,
              revision TEXT,
              global_revision TEXT,
              cached_at INTEGER NOT NULL,
              PRIMARY KEY (account_key, path)
            )
          ''');
            await db.execute('''
            CREATE TABLE transient_objects (
              account_key TEXT NOT NULL,
              hash TEXT NOT NULL,
              size INTEGER NOT NULL,
              last_accessed_at INTEGER NOT NULL,
              PRIMARY KEY (account_key, hash)
            )
          ''');
            await db.execute('''
            CREATE TABLE offline_targets (
              account_key TEXT NOT NULL,
              target_path TEXT NOT NULL,
              target_name TEXT NOT NULL,
              state TEXT NOT NULL,
              scan_complete INTEGER NOT NULL,
              estimate_files INTEGER,
              estimate_bytes INTEGER,
              estimate_has_unknown INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              PRIMARY KEY (account_key, target_path)
            )
          ''');
            await db.execute('''
            CREATE TABLE offline_target_frontier (
              account_key TEXT NOT NULL,
              target_path TEXT NOT NULL,
              folder_path TEXT NOT NULL,
              next_offset INTEGER NOT NULL,
              state TEXT NOT NULL,
              sequence INTEGER NOT NULL,
              error_code TEXT,
              PRIMARY KEY (account_key, target_path, folder_path)
            )
          ''');
            await db.execute('''
            CREATE TABLE offline_target_files (
              account_key TEXT NOT NULL,
              target_path TEXT NOT NULL,
              file_path TEXT NOT NULL,
              name TEXT NOT NULL,
              hash TEXT,
              size INTEGER,
              modified_at INTEGER,
              revision TEXT,
              global_revision TEXT,
              readiness TEXT NOT NULL,
              bytes_done INTEGER NOT NULL,
              error_code TEXT,
              last_seen_scan_id INTEGER,
              updated_at INTEGER NOT NULL,
              PRIMARY KEY (account_key, target_path, file_path)
            )
          ''');
            final account = accountCacheKey('legacy@mail.ru');
            const lowerHash = '00112233445566778899aabbccddeeff00112233';
            await db.insert('offline_files', {
              'account_key': account,
              'path': '/direct.txt',
              'name': 'direct.txt',
              'hash': lowerHash,
              'size': 1,
              'cached_at': 1000,
            });
            await db.insert('transient_objects', {
              'account_key': account,
              'hash': lowerHash,
              'size': 1,
              'last_accessed_at': 1000,
            });
            await db.insert('offline_targets', {
              'account_key': account,
              'target_path': '/legacy',
              'target_name': 'legacy',
              'state': 'ready',
              'scan_complete': 1,
              'estimate_has_unknown': 1,
              'created_at': 1000,
              'updated_at': 1000,
            });
            await db.insert('offline_target_frontier', {
              'account_key': account,
              'target_path': '/legacy',
              'folder_path': '/legacy',
              'next_offset': 0,
              'state': 'complete',
              'sequence': 0,
            });
            await db.insert('offline_target_files', {
              'account_key': account,
              'target_path': '/legacy',
              'file_path': '/legacy/file.txt',
              'name': 'file.txt',
              'hash': lowerHash,
              'size': 1,
              'readiness': 'ready',
              'bytes_done': 1,
              'updated_at': 1000,
            });
          },
        ),
      );
      await database.close();

      final index = _index(root);
      addTearDown(() async {
        await index.close();
        await root.delete(recursive: true);
      });
      final target = await index.getTarget('legacy@mail.ru', '/legacy');
      expect(target?.targetIncarnation, startsWith('legacy_v5_'));
      expect(
        (await index.getTargetFile(
          'legacy@mail.ru',
          '/legacy',
          '/legacy/file.txt',
        ))?.hash,
        '00112233445566778899AABBCCDDEEFF00112233',
      );
      expect(
        await index.hasHashReference(
          'legacy@mail.ru',
          '00112233445566778899aabbccddeeff00112233',
        ),
        isTrue,
      );
      expect(
        await index.hasTransientReference(
          'legacy@mail.ru',
          '00112233445566778899aabbccddeeff00112233',
        ),
        isTrue,
      );
    },
  );
}

SqliteOfflineFileIndex _index(Directory root) => SqliteOfflineFileIndex(
  rootProvider: FixedCacheRoot(root),
  databaseFactory: databaseFactoryFfi,
);

OfflineTargetRecord _target(
  String path, {
  OfflineTargetState state = OfflineTargetState.planning,
  bool scanComplete = false,
  String incarnation = 'test-incarnation',
}) {
  final now = DateTime.utc(2025);
  final normalizedPath = normalizeOfflineRemotePath(path);
  return OfflineTargetRecord(
    targetPath: path,
    targetIncarnation: incarnation,
    targetName: normalizedPath == '/'
        ? 'root'
        : normalizedPath.substring(normalizedPath.lastIndexOf('/') + 1),
    state: state,
    scanComplete: scanComplete,
    estimateHasUnknown: true,
    createdAt: now,
    updatedAt: now,
  );
}

OfflineTargetFrontierRecord _frontier(
  String targetPath,
  String folderPath, {
  required int sequence,
  OfflineTargetFrontierState state = OfflineTargetFrontierState.pending,
  String incarnation = 'test-incarnation',
}) => OfflineTargetFrontierRecord(
  targetPath: targetPath,
  targetIncarnation: incarnation,
  folderPath: folderPath,
  nextOffset: 0,
  state: state,
  sequence: sequence,
);

OfflineTargetFileRecord _targetFile(
  String targetPath,
  String filePath, {
  String? hash,
  int? size = 1,
  OfflineReadiness readiness = OfflineReadiness.ready,
  String incarnation = 'test-incarnation',
}) => OfflineTargetFileRecord(
  targetPath: targetPath,
  targetIncarnation: incarnation,
  filePath: filePath,
  name: filePath.substring(filePath.lastIndexOf('/') + 1),
  hash: hash,
  size: size,
  readiness: readiness,
  bytesDone: 0,
  updatedAt: DateTime.utc(2025),
);
