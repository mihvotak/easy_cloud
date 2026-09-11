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

  test('enumerates only sorted canonical final objects', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-cache');
    addTearDown(() => root.delete(recursive: true));
    final cache = ContentAddressedFileCache(root: root, email: 'user@mail.ru');
    const firstHash = '00112233445566778899AABBCCDDEEFF00112233';
    const secondHash = 'AABBCCDDEEFF00112233445566778899AABBCCDD';
    const directoryHash = '11223344556677889900AABBCCDDEEFF11223344';
    const symlinkHash = 'FFEEDDCCBBAA99887766554433221100FFEEDDCC';

    final first = await cache.objectFile(firstHash);
    await first.parent.create(recursive: true);
    await first.writeAsBytes(const [1]);
    final second = await cache.objectFile(secondHash);
    await second.parent.create(recursive: true);
    await second.writeAsBytes(const [2]);

    final part = await cache.partFile(firstHash);
    await part.writeAsBytes(const [3]);
    await File('${first.path}.unknown').writeAsBytes(const [4]);
    if (!Platform.isWindows) {
      await File(
        '${first.parent.path}${Platform.pathSeparator}${firstHash.toLowerCase()}',
      ).writeAsBytes(const [5]);
    }
    final mismatchedDirectory = Directory(
      '${first.parent.parent.path}${Platform.pathSeparator}CC',
    );
    await mismatchedDirectory.create(recursive: true);
    final mismatched = File(
      '${mismatchedDirectory.path}${Platform.pathSeparator}$firstHash',
    );
    await mismatched.writeAsBytes(const [6]);

    final directoryObject = await cache.objectFile(directoryHash);
    await Directory(directoryObject.path).create(recursive: true);
    final symlinkObject = await cache.objectFile(symlinkHash);
    await symlinkObject.parent.create(recursive: true);
    final linkTarget = File('${root.path}${Platform.pathSeparator}outside');
    await linkTarget.writeAsBytes(const [7]);
    var symlinkCreated = false;
    try {
      await Link(symlinkObject.path).create(linkTarget.path);
      symlinkCreated = true;
    } on FileSystemException {
      // Windows CI may not grant symlink creation to the test process.
    }

    final candidates = await cache.enumerateFinalObjects();

    expect(candidates.map((candidate) => candidate.hash), [
      firstHash,
      secondHash,
    ]);
    expect(await part.exists(), isTrue);
    expect(await File('${first.path}.unknown').exists(), isTrue);
    expect(await mismatched.exists(), isTrue);
    if (symlinkCreated) {
      expect(
        await FileSystemEntity.type(symlinkObject.path, followLinks: false),
        FileSystemEntityType.link,
      );
    }
  });

  test('enumerating a missing account directory is a no-op', () async {
    final root = await Directory.systemTemp.createTemp('easy-cloud-cache');
    addTearDown(() => root.delete(recursive: true));

    final candidates = await ContentAddressedFileCache(
      root: root,
      email: 'missing@mail.ru',
    ).enumerateFinalObjects();

    expect(candidates, isEmpty);
  });
}
