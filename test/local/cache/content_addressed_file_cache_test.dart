import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easy_cloud/local/cache/content_addressed_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses an email hash and a two-level content hash path', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-cache');
    addTearDown(() => root.delete(recursive: true));
    const email = '  User@Mail.RU ';
    const hash = 'AABBCCDDEEFF00112233445566778899AABBCCDD';
    final cache = ContentAddressedFileCache(root: root, email: email);

    final paths = await cache.paths(hash);
    final expectedAccount = sha256
        .convert(utf8.encode('user@mail.ru'))
        .toString();
    expect(
      paths.objectFile.path,
      contains(
        '${Platform.pathSeparator}cloud_cache${Platform.pathSeparator}$expectedAccount${Platform.pathSeparator}objects',
      ),
    );
    expect(
      paths.objectFile.path,
      endsWith(
        '${Platform.pathSeparator}objects${Platform.pathSeparator}AA${Platform.pathSeparator}BB${Platform.pathSeparator}$hash',
      ),
    );
    expect(paths.partFile.path, endsWith('$hash.part'));
  });

  test(
    'lookup validates size and commit moves only the verified part',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-cache');
      addTearDown(() => root.delete(recursive: true));
      const hash = '00112233445566778899AABBCCDDEEFF00112233';
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'user@mail.ru',
      );
      final part = await cache.partFile(hash);
      final damagedObject = await cache.objectFile(hash);
      await damagedObject.writeAsBytes([9]);
      await part.writeAsBytes([1, 2, 3]);

      expect(await cache.lookup(hash, expectedSize: 4), isNull);
      await cache.discardObject(hash);
      expect(await damagedObject.exists(), isFalse);
      expect(await cache.lookup(hash, expectedSize: 3), isNull);

      await cache.commit(hash, part);

      final object = await cache.lookup(hash, expectedSize: 3);
      expect(object, isNotNull);
      expect(await object!.readAsBytes(), [1, 2, 3]);
      expect(await part.exists(), isFalse);
      expect(await cache.lookup(hash, expectedSize: 4), isNull);
    },
  );

  test(
    'keeps an existing immutable object and removes a duplicate part',
    () async {
      final root = await Directory.systemTemp.createTemp('easy-cloud-cache');
      addTearDown(() => root.delete(recursive: true));
      const hash = '00112233445566778899AABBCCDDEEFF00112233';
      final cache = ContentAddressedFileCache(
        root: root,
        email: 'user@mail.ru',
      );
      final object = await cache.objectFile(hash);
      final part = await cache.partFile(hash);
      await object.writeAsBytes([9]);
      await part.writeAsBytes([1, 2, 3]);

      await cache.commit(hash, part);

      expect(await object.readAsBytes(), [9]);
      expect(await part.exists(), isFalse);
    },
  );

  test('rejects hashes that could escape the object directory', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-cache');
    addTearDown(() => root.delete(recursive: true));
    final cache = ContentAddressedFileCache(root: root, email: 'user@mail.ru');

    expect(() => cache.paths('../not-a-hash'), throwsA(isA<ArgumentError>()));
  });
}
