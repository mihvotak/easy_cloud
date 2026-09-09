import 'dart:convert';

import 'package:easy_cloud/cloud_mail/probe/response_shape.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('describes JSON structure without including values', () {
    final shape = responseShape(
      utf8.encode(
        '{"access_token":"very-secret","body":{"list":[{"name":"private.txt"}]}}',
      ),
      contentType: 'application/json',
    );

    expect(shape, contains('access_token:string'));
    expect(shape, contains('body:object'));
    expect(shape, isNot(contains('very-secret')));
    expect(shape, isNot(contains('private.txt')));
  });

  test('distinguishes empty, text, and binary responses', () {
    expect(responseShape(const []), 'empty');
    expect(
      responseShape(utf8.encode('shard.example 127.0.0.1 1')),
      startsWith('text('),
    );
    expect(responseShape(const [0xff, 0xfe, 0xfd]), 'binary(3 bytes)');
    expect(
      responseShape(
        utf8.encode('printable bytes'),
        contentType: 'application/octet-stream',
      ),
      'binary(15 bytes)',
    );
  });

  test('does not expose malformed JSON', () {
    expect(
      responseShape(
        utf8.encode('{"password":"secret"'),
        contentType: 'application/json',
      ),
      startsWith('invalid-json('),
    );
  });
}
