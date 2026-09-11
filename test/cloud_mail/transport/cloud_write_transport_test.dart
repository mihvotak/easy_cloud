import 'dart:convert';

import 'package:easy_cloud/cloud_mail/transport/cloud_transport.dart';
import 'package:easy_cloud/cloud_mail/transport/cloud_write_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const hash = '00112233445566778899AABBCCDDEEFF00112233';

  test('parses the exact upload-shard response grammar', () {
    final sized = parseCloudUploadShardResponse('$hash;0', expectedSize: 0);
    expect(sized.hash, hash);
    expect(sized.size, 0);
    final unsized = parseCloudUploadShardResponse(
      hash.toLowerCase(),
      expectedSize: 42,
    );
    expect(unsized.hash, hash);
    expect(unsized.size, isNull);
  });

  test('rejects an upload response with a mismatched size', () {
    expect(
      () => parseCloudUploadShardResponse('$hash;41', expectedSize: 42),
      throwsA(
        isA<CloudWriteFailure>().having(
          (failure) => failure.type,
          'type',
          CloudWriteFailureType.integrity,
        ),
      ),
    );
  });

  test('parses and validates a file/add path response', () {
    final response = CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(
        jsonEncode({'status': 200, 'body': '/docs/report.txt'}),
      ),
    );

    final result = parseCloudFileAddResponse(
      response,
      requestedPath: '/docs/report.txt',
      conflict: CloudWriteConflictMode.strict,
    );

    expect(result.requestedPath, '/docs/report.txt');
    expect(result.returnedPath, '/docs/report.txt');
    expect(result.conflict, CloudWriteConflictMode.strict);
  });

  test('requires a server-selected adjacent path for rename', () {
    final response = CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(
        jsonEncode({'status': 200, 'body': '/docs/report (1).txt'}),
      ),
    );

    final result = parseCloudFileAddResponse(
      response,
      requestedPath: '/docs/report.txt',
      conflict: CloudWriteConflictMode.rename,
    );

    expect(result.returnedPath, '/docs/report (1).txt');
  });

  test('rejects unknown API errors and unsafe returned paths', () {
    final errorResponse = CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(
        jsonEncode({
          'status': 200,
          'error': 'new_server_error',
          'body': '/docs/report.txt',
        }),
      ),
    );
    final unsafeResponse = CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(
        jsonEncode({'status': 200, 'body': '/docs/../report.txt'}),
      ),
    );

    expect(
      () => parseCloudFileAddResponse(
        errorResponse,
        requestedPath: '/docs/report.txt',
        conflict: CloudWriteConflictMode.strict,
      ),
      throwsA(
        isA<CloudWriteFailure>().having(
          (failure) => failure.type,
          'type',
          CloudWriteFailureType.service,
        ),
      ),
    );
    expect(
      () => parseCloudFileAddResponse(
        unsafeResponse,
        requestedPath: '/docs/report.txt',
        conflict: CloudWriteConflictMode.strict,
      ),
      throwsA(isA<CloudWriteFailure>()),
    );
  });

  test('classifies nested file/add auth errors', () {
    final response = CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(
        jsonEncode({
          'status': 200,
          'body': {
            'home': {'error': 'token'},
          },
        }),
      ),
    );

    expect(
      () => parseCloudFileAddResponse(
        response,
        requestedPath: '/docs/report.txt',
        conflict: CloudWriteConflictMode.strict,
      ),
      throwsA(
        isA<CloudWriteFailure>().having(
          (failure) => failure.type,
          'type',
          CloudWriteFailureType.authRequired,
        ),
      ),
    );
  });

  test('requires an integer response status matching the HTTP status', () {
    final missingStatus = CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(jsonEncode({'body': '/docs/report.txt'})),
    );
    final mismatchedStatus = CloudResponse(
      statusCode: 201,
      bytes: utf8.encode(
        jsonEncode({'status': 200, 'body': '/docs/report.txt'}),
      ),
    );
    final stringStatus = CloudResponse(
      statusCode: 200,
      bytes: utf8.encode(
        jsonEncode({'status': '200', 'body': '/docs/report.txt'}),
      ),
    );

    for (final response in [missingStatus, mismatchedStatus, stringStatus]) {
      expect(
        () => parseCloudFileAddResponse(
          response,
          requestedPath: '/docs/report.txt',
          conflict: CloudWriteConflictMode.rewrite,
        ),
        throwsA(
          isA<CloudWriteFailure>().having(
            (failure) => failure.type,
            'type',
            CloudWriteFailureType.invalidResponse,
          ),
        ),
      );
    }
  });

  test('treats an unconfirmed 403 as permission denied', () {
    final response = CloudResponse(
      statusCode: 403,
      bytes: utf8.encode(jsonEncode({'status': 403, 'body': 'readonly'})),
    );

    expect(
      () => parseCloudFileAddResponse(
        response,
        requestedPath: '/docs/report.txt',
        conflict: CloudWriteConflictMode.rewrite,
      ),
      throwsA(
        isA<CloudWriteFailure>().having(
          (failure) => failure.type,
          'type',
          CloudWriteFailureType.permissionDenied,
        ),
      ),
    );
  });

  test('accepts only HTTPS Mail.ru upload shards', () {
    expect(
      isTrustedCloudWriteShard(Uri.parse('https://cld123.cloud.mail.ru/u')),
      isTrue,
    );
    expect(
      isTrustedCloudWriteShard(Uri.parse('http://127.0.0.1:8080/u')),
      isFalse,
    );
    expect(
      isTrustedCloudWriteShard(Uri.parse('https://evil.example/u')),
      isFalse,
    );
    expect(
      isTrustedCloudWriteShard(
        Uri.parse('https://cld123.cloud.mail.ru/u?token=leak'),
      ),
      isFalse,
    );
  });

  test('parses the dispatcher URL before its optional metadata fields', () {
    final shard = parseCloudWriteDispatcherResponse(
      'https://cld123.cloud.mail.ru/upload 192.0.2.10 3',
    );
    expect(shard.toString(), 'https://cld123.cloud.mail.ru/upload');
  });
}
