import 'dart:io';

import 'package:easy_cloud/features/offline/data/sqlite_offline_file_index.dart';
import 'package:easy_cloud/features/offline/domain/offline_file_record.dart';
import 'package:easy_cloud/local/cache/application_cache_root.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('round-trips optional metadata and normalizes path/hash', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });
    final modifiedAt = DateTime.utc(2025, 1, 2, 3, 4, 5, 6);
    final cachedAt = DateTime.utc(2025, 1, 3, 4, 5, 6, 7);

    await index.upsert(
      ' User@Mail.RU ',
      OfflineFileRecord(
        path: 'docs/report.pdf/',
        name: 'report.pdf',
        hash: ' aabbccddeeff00112233445566778899aabbccdd ',
        size: 42,
        modifiedAt: modifiedAt,
        revision: 'r1',
        globalRevision: 'g1',
        cachedAt: cachedAt,
      ),
    );

    final records = await index.list('user@mail.ru');
    expect(records, hasLength(1));
    expect(records.single.path, '/docs/report.pdf');
    expect(records.single.hash, 'AABBCCDDEEFF00112233445566778899AABBCCDD');
    expect(records.single.size, 42);
    expect(records.single.modifiedAt, modifiedAt);
    expect(records.single.revision, 'r1');
    expect(records.single.globalRevision, 'g1');
    expect(records.single.cachedAt, cachedAt);
  });

  test('upsert replaces the same normalized account/path', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });

    await index.upsert('user@mail.ru', _record('same.txt', cachedAt: 1));
    await index.upsert(
      'USER@MAIL.RU',
      _record('/same.txt/', name: 'new.txt', cachedAt: 2),
    );

    final records = await index.list(' user@mail.ru ');
    expect(records, hasLength(1));
    expect(records.single.name, 'new.txt');
    expect(records.single.cachedAt, _time(2));
  });

  test('isolates accounts and orders by cached time then path', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });

    await index.upsert('first@mail.ru', _record('/z.txt', cachedAt: 10));
    await index.upsert('first@mail.ru', _record('/a.txt', cachedAt: 10));
    await index.upsert('first@mail.ru', _record('/new.txt', cachedAt: 11));
    await index.upsert('second@mail.ru', _record('/other.txt', cachedAt: 99));

    expect((await index.list('first@mail.ru')).map((record) => record.path), [
      '/new.txt',
      '/a.txt',
      '/z.txt',
    ]);
    expect((await index.list('second@mail.ru')).map((record) => record.path), [
      '/other.txt',
    ]);
  });

  test(
    'lookup returns canonical existing paths and isolates accounts',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
      final index = _index(root);
      addTearDown(() async {
        await index.close();
        await root.delete(recursive: true);
      });

      await index.upsert(
        'first@mail.ru',
        _record('docs/report.pdf', cachedAt: 1),
      );
      await index.upsert(
        'first@mail.ru',
        _record('/docs/notes.txt', cachedAt: 2),
      );
      await index.upsert(
        'second@mail.ru',
        _record('/docs/report.pdf', cachedAt: 3),
      );

      final result = await index.lookup(' FIRST@MAIL.RU ', [
        'docs/report.pdf/',
        '/docs/report.pdf',
        'docs/missing.txt/',
        '/docs/notes.txt',
      ]);

      expect(result.keys, containsAll(['/docs/report.pdf', '/docs/notes.txt']));
      expect(result, hasLength(2));
      expect(result['/docs/report.pdf']?.path, '/docs/report.pdf');
      expect(
        await index.lookup('second@mail.ru', ['docs/report.pdf']),
        hasLength(1),
      );
    },
  );

  test('lookup validates paths and has an empty fast path', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });

    expect(await index.lookup('user@mail.ru', const []), isEmpty);
    expect(await Directory(p.join(root.path, 'cloud_cache')).exists(), isFalse);
    await expectLater(
      index.lookup('user@mail.ru', ['/bad/../path']),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('lookup chunks a large path set below SQLite variable limits', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });
    const count = 1001;

    for (var number = 0; number < count; number++) {
      await index.upsert(
        'bulk@mail.ru',
        _record('/bulk/file-$number.txt', cachedAt: number),
      );
    }

    final result = await index.lookup(
      'bulk@mail.ru',
      List.generate(count, (number) => 'bulk/file-$number.txt/'),
    );

    expect(result, hasLength(count));
    expect(result['/bulk/file-0.txt']?.path, '/bulk/file-0.txt');
    expect(result['/bulk/file-1000.txt']?.path, '/bulk/file-1000.txt');
  });

  test('removes one path and clears only one account', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });

    await index.upsert('first@mail.ru', _record('/remove.txt', cachedAt: 1));
    await index.upsert('first@mail.ru', _record('/keep.txt', cachedAt: 2));
    await index.upsert('second@mail.ru', _record('/keep.txt', cachedAt: 3));

    await index.remove('first@mail.ru', 'remove.txt/');
    expect((await index.list('first@mail.ru')).map((record) => record.path), [
      '/keep.txt',
    ]);

    await index.clearAccount('first@mail.ru');
    expect(await index.list('first@mail.ru'), isEmpty);
    expect(await index.list('second@mail.ru'), hasLength(1));
  });

  test('hasHashReference normalizes hashes and isolates accounts', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });
    const hash = '00112233445566778899AABBCCDDEEFF00112233';

    await index.upsert(
      'first@mail.ru',
      _record('/first.txt', cachedAt: 1, hash: ' $hash '),
    );
    await index.upsert(
      'second@mail.ru',
      _record('/second.txt', cachedAt: 2, hash: hash),
    );

    expect(
      await index.hasHashReference(' FIRST@MAIL.RU ', hash.toLowerCase()),
      isTrue,
    );
    expect(await index.hasHashReference('second@mail.ru', hash), isTrue);
    expect(
      await index.hasHashReference(
        'third@mail.ru',
        '8899AABBCCDDEEFF00112233445566778899AABB',
      ),
      isFalse,
    );

    await index.remove('first@mail.ru', '/first.txt');
    expect(await index.hasHashReference('first@mail.ru', hash), isFalse);
    expect(await index.hasHashReference('second@mail.ru', hash), isTrue);
  });

  test('serializes concurrent lazy opens and upserts', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });

    await Future.wait(
      List.generate(
        32,
        (number) => index.upsert(
          'concurrent@mail.ru',
          _record('/file-$number.txt', cachedAt: number),
        ),
      ),
    );

    final records = await index.list('concurrent@mail.ru');
    expect(records, hasLength(32));
    expect(records.first.path, '/file-31.txt');
  });

  test('rejects invalid record values and paths', () async {
    expect(
      () => OfflineFileRecord(
        path: '/file.txt',
        name: 'file.txt',
        hash: 'not-a-hash',
        size: 0,
        cachedAt: _time(1),
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => OfflineFileRecord(
        path: '/file.txt',
        name: 'file.txt',
        hash: '00112233445566778899AABBCCDDEEFF00112233',
        size: -1,
        cachedAt: _time(1),
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => OfflineFileRecord(
        path: '/folder/../file.txt',
        name: 'file.txt',
        hash: '00112233445566778899AABBCCDDEEFF00112233',
        size: 0,
        cachedAt: _time(1),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('close is idempotent and prevents reopening', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() => root.delete(recursive: true));

    await index.close();
    await index.close();

    await expectLater(index.list('user@mail.ru'), throwsA(isA<StateError>()));
    await expectLater(
      index.upsert('user@mail.ru', _record('/file.txt', cachedAt: 1)),
      throwsA(isA<StateError>()),
    );
    expect(await Directory(p.join(root.path, 'cloud_cache')).exists(), isFalse);
  });

  test('schema stores account keys, not raw emails', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-offline');
    final index = _index(root);
    addTearDown(() async {
      await index.close();
      await root.delete(recursive: true);
    });
    const email = 'private-user@mail.ru';
    await index.upsert(email, _record('/secret.txt', cachedAt: 1));
    await index.close();

    final database = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'cloud_cache', SqliteOfflineFileIndex.databaseFileName),
    );
    addTearDown(database.close);
    final columns = await database.rawQuery(
      'PRAGMA table_info(${SqliteOfflineFileIndex.tableName})',
    );
    final columnNames = columns.map((row) => row['name']);
    expect(columnNames, isNot(contains('email')));
    expect(columnNames, contains('account_key'));
    expect(await database.rawQuery('PRAGMA user_version'), [
      {'user_version': SqliteOfflineFileIndex.schemaVersion},
    ]);
    final rows = await database.query(SqliteOfflineFileIndex.tableName);
    expect(rows.single.values, isNot(contains(email)));
  });
}

SqliteOfflineFileIndex _index(Directory root) => SqliteOfflineFileIndex(
  rootProvider: FixedCacheRoot(root),
  databaseFactory: databaseFactoryFfi,
);

OfflineFileRecord _record(
  String path, {
  String name = 'file.txt',
  required int cachedAt,
  String hash = '00112233445566778899AABBCCDDEEFF00112233',
}) => OfflineFileRecord(
  path: path,
  name: name,
  hash: hash,
  size: 1,
  cachedAt: _time(cachedAt),
);

DateTime _time(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
