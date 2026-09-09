import 'dart:io';

import 'package:easy_cloud/cloud_mail/probe/cloud_hash.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('calculateCloudHash', () {
    test('pads an empty payload to twenty bytes', () {
      expect(calculateCloudHash(const []), List.filled(40, '0').join());
    });

    test('pads a small payload with zero bytes', () {
      expect(
        calculateCloudHash(const [0x41]),
        '4100000000000000000000000000000000000000',
      );
    });

    test('keeps exactly twenty bytes as uppercase hex', () {
      expect(
        calculateCloudHash(List.filled(20, 0xff)),
        'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
      );
    });

    test('switches to SHA1 for twenty-one bytes', () {
      final hash = calculateCloudHash(List.filled(21, 0xab));

      expect(hash, hasLength(40));
      expect(hash, matches(RegExp(r'^[0-9A-F]{40}$')));
      expect(hash, isNot(List.filled(20, 'AB').join()));
    });
  });

  test('streaming file hash matches the in-memory hash', () async {
    final directory = await Directory.systemTemp.createTemp('easy-cloud-hash');
    addTearDown(() => directory.delete(recursive: true));
    final bytes = List<int>.generate(128 * 1024, (index) => index % 251);
    final file = File('${directory.path}/payload.bin');
    await file.writeAsBytes(bytes);

    expect(await calculateCloudFileHash(file), calculateCloudHash(bytes));
  });
}
