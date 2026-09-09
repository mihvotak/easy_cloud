import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _cloudHashPrefix = 'mrCloud';
const _smallFileLimit = 20;

Future<String> calculateCloudFileHash(File file) async {
  final size = await file.length();
  if (size <= _smallFileLimit) {
    return calculateCloudHash(await file.readAsBytes());
  }

  final digestSink = _DigestSink();
  final input = sha1.startChunkedConversion(digestSink);
  input.add(utf8.encode(_cloudHashPrefix));
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.add(ascii.encode(size.toString()));
  input.close();
  return digestSink.digest.toString().toUpperCase();
}

String calculateCloudHash(List<int> bytes) {
  if (bytes.length <= _smallFileLimit) {
    final padded = Uint8List(_smallFileLimit)..setAll(0, bytes);
    return _hex(padded);
  }

  final digest = sha1.convert([
    ...utf8.encode(_cloudHashPrefix),
    ...bytes,
    ...ascii.encode(bytes.length.toString()),
  ]);
  return digest.toString().toUpperCase();
}

String _hex(List<int> bytes) => bytes
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join()
    .toUpperCase();

final class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest {
    final value = _digest;
    if (value == null) {
      throw StateError('Hash conversion has not completed.');
    }
    return value;
  }

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}
