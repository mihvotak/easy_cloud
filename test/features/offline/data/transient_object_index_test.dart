import 'dart:io';

import 'package:easy_cloud/features/offline/data/sqlite_offline_file_index.dart';
import 'package:easy_cloud/features/offline/domain/transient_object_record.dart';
import 'package:easy_cloud/local/cache/application_cache_root.dart';
import 'package:easy_cloud/local/cache/content_addressed_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'fresh schema stores account-isolated deterministic transient LRU',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'easy-cloud-transient',
      );
      final index = _index(root);
      addTearDown(() async {
        await index.close();
        await root.delete(recursive: true);
      });

      final first = _hash('0011');
      final second = _hash('0022');
      final other = _hash('0033');
      await index.touchTransient('FIRST@mail.ru', _transient(first, 10, 1));
      await index.touchTransient('first@mail.ru', _transient(second, 20, 1));
      await index.touchTransient('second@mail.ru', _transient(other, 30, 1));

      expect(
        (await index.listTransient(
          'first@mail.ru',
        )).map((record) => record.hash),
        [first, second],
      );
      expect(
        (await index.listTransient(
          'second@mail.ru',
        )).map((record) => record.hash),
        [other],
      );
      expect(
        await index.hasTransientReference(
          ' FIRST@MAIL.RU ',
          first.toLowerCase(),
        ),
        isTrue,
      );
      expect(
        await index.hasTransientReference('second@mail.ru', first),
        isFalse,
      );

      await index.touchTransient('first@mail.ru', _transient(first, 11, 2));
      expect(
        (await index.listTransient(
          'first@mail.ru',
        )).map((record) => record.hash),
        [second, first],
      );
      expect((await index.listTransient('first@mail.ru')).last.size, 11);

      await index.removeTransient('first@mail.ru', second);
      expect(
        await index.hasTransientReference('first@mail.ru', second),
        isFalse,
      );
    },
  );

  test('fresh schema has v4 transient table and no raw email column', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-transient');
    final index = _index(root);
    await index.touchTransient(
      'private@mail.ru',
      _transient(_hash('0044'), 1, 1),
    );
    await index.close();

    final database = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'cloud_cache', SqliteOfflineFileIndex.databaseFileName),
    );
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    expect(await database.rawQuery('PRAGMA user_version'), [
      {'user_version': SqliteOfflineFileIndex.schemaVersion},
    ]);
    final columns = await database.rawQuery(
      'PRAGMA table_info(${SqliteOfflineFileIndex.transientObjectsTableName})',
    );
    final names = columns.map((row) => row['name']);
    expect(
      names,
      containsAll(['account_key', 'hash', 'size', 'last_accessed_at']),
    );
    expect(names, isNot(contains('email')));
    final indexes = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
      [SqliteOfflineFileIndex.transientObjectsTableName],
    );
    expect(
      indexes.map((row) => row['name']),
      contains('transient_objects_account_lru_idx'),
    );
  });

  test('upgrades v3 additively and preserves offline rows', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-transient');
    final databasePath = p.join(
      root.path,
      'cloud_cache',
      SqliteOfflineFileIndex.databaseFileName,
    );
    final directory = Directory(p.dirname(databasePath));
    await directory.create(recursive: true);
    final database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (database, _) async {
          await database.execute('''
            CREATE TABLE offline_files (
              account_key TEXT NOT NULL,
              path TEXT NOT NULL,
              name TEXT NOT NULL,
              hash TEXT NOT NULL,
              size INTEGER NOT NULL CHECK (size >= 0),
              modified_at INTEGER,
              revision TEXT,
              global_revision TEXT,
              cached_at INTEGER NOT NULL,
              PRIMARY KEY (account_key, path)
            )
          ''');
          await database.execute('''
            CREATE INDEX offline_files_account_cached_at_idx
            ON offline_files (account_key, cached_at DESC, path ASC)
          ''');
          await database.execute('''
            CREATE INDEX offline_files_account_hash_idx
            ON offline_files (account_key, hash)
          ''');
        },
      ),
    );
    await database.insert('offline_files', {
      'account_key': accountCacheKey('v3@mail.ru'),
      'path': '/kept.txt',
      'name': 'kept.txt',
      'hash': _hash('0055'),
      'size': 7,
      'cached_at': _time(1).microsecondsSinceEpoch,
    });
    await database.close();

    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });
    expect((await index.list('v3@mail.ru')).single.path, '/kept.txt');
    await index.touchTransient('v3@mail.ru', _transient(_hash('0066'), 2, 2));
    expect(
      await index.hasTransientReference('v3@mail.ru', _hash('0066')),
      isTrue,
    );
    await index.close();

    final migrated = await databaseFactoryFfi.openDatabase(databasePath);
    addTearDown(migrated.close);
    expect(await migrated.rawQuery('PRAGMA user_version'), [
      {'user_version': SqliteOfflineFileIndex.schemaVersion},
    ]);
    expect(
      await migrated.rawQuery(
        'SELECT path FROM ${SqliteOfflineFileIndex.tableName}',
      ),
      [
        {'path': '/kept.txt'},
      ],
    );
    expect(
      await migrated.rawQuery(
        'SELECT name FROM sqlite_master WHERE type = \'table\' AND name = ?',
        [SqliteOfflineFileIndex.transientObjectsTableName],
      ),
      hasLength(1),
    );
  });

  test('validates transient record values', () {
    expect(
      () => TransientObjectRecord(
        hash: 'not-a-hash',
        size: 1,
        lastAccessedAt: _time(1),
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => TransientObjectRecord(
        hash: _hash('0077'),
        size: -1,
        lastAccessedAt: _time(1),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}

SqliteOfflineFileIndex _index(Directory root) => SqliteOfflineFileIndex(
  rootProvider: FixedCacheRoot(root),
  databaseFactory: databaseFactoryFfi,
);

TransientObjectRecord _transient(String hash, int size, int seconds) =>
    TransientObjectRecord(
      hash: hash,
      size: size,
      lastAccessedAt: _time(seconds),
    );

String _hash(String suffix) =>
    '${suffix.toUpperCase()}000000000000000000000000000000000000';

DateTime _time(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
