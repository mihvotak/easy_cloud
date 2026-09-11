import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/cloud_probe/probe_client.dart';
import '../../../tool/cloud_probe/probe_options.dart';

void main() {
  final hash = List.filled(40, 'a').join();

  group('parseUploadShardResponse', () {
    test('accepts a bare hash', () {
      final result = parseUploadShardResponse(hash, expectedSize: 7);

      expect(result.hash, hash.toUpperCase());
      expect(result.size, isNull);
    });

    test('accepts a hash with a matching decimal size', () {
      final result = parseUploadShardResponse('$hash;7\n', expectedSize: 7);

      expect(result.hash, hash.toUpperCase());
      expect(result.size, 7);
    });

    test('rejects a hash with a different server size', () {
      expect(
        () => parseUploadShardResponse('$hash;8', expectedSize: 7),
        throwsA(isA<ProbeException>()),
      );
    });

    test('rejects fields outside the two supported grammars', () {
      expect(
        () => parseUploadShardResponse('$hash;7;extra', expectedSize: 7),
        throwsA(isA<ProbeException>()),
      );
      expect(
        () => parseUploadShardResponse('$hash anything', expectedSize: 7),
        throwsA(isA<ProbeException>()),
      );
    });
  });

  test(
    'registerByIdentity returns a safe path and classifies exists',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requestCount = 0;
      server.listen((request) async {
        await request.drain();
        final response = request.response;
        response.headers.contentType = ContentType.json;
        if (requestCount++ == 0) {
          response.write('{"status":200,"body":"/probe/original (1).txt"}');
        } else {
          response.statusCode = HttpStatus.badRequest;
          response.write('{"status":400,"body":{"home":{"error":"exists"}}}');
        }
        await response.close();
      });

      final options = ProbeOptions.parse([
        'test',
        '--api-url=http://${server.address.host}:${server.port}/api/v2/',
      ]);
      final client = CloudProbeClient(options);
      final session = OAuthSession(
        accessToken: '',
        refreshToken: null,
        expiresIn: null,
      );
      final identity = CloudFileIdentity(
        hash: List.filled(40, 'b').join(),
        size: 12,
      );

      try {
        final renamed = await client.registerByIdentity(
          session,
          identity,
          '/probe/original.txt',
          conflict: FileConflict.rename,
        );
        final strict = await client.registerByIdentity(
          session,
          identity,
          '/probe/original.txt',
          conflict: FileConflict.strict,
        );

        expect(renamed.succeeded, isTrue);
        expect(renamed.returnedPath, '/probe/original (1).txt');
        expect(strict.succeeded, isFalse);
        expect(strict.error, FileAddError.exists);
        expect(strict.statusCode, HttpStatus.badRequest);
      } finally {
        client.close();
        await server.close(force: true);
      }
    },
  );
}
