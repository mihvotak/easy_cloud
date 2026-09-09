import 'package:easy_cloud/cloud_mail/probe/redactor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('redacts sensitive fields regardless of header spelling', () {
    final result = redactFields({
      'password': 'secret',
      'access_token': 'access',
      'X-CSRF-Token': 'csrf',
      'Cookie': 'session',
      'home': '/Documents',
    });

    expect(result['password'], redactedValue);
    expect(result['access_token'], redactedValue);
    expect(result['X-CSRF-Token'], redactedValue);
    expect(result['Cookie'], redactedValue);
    expect(result['home'], '/Documents');
  });

  test('redacts token query parameters in logged URLs', () {
    final result = redactUri(
      Uri.parse(
        'https://example.test/file?home=%2Fnote.txt&token=secret&access_token=other',
      ),
    );

    expect(result.queryParameters['home'], '/note.txt');
    expect(result.queryParameters['token'], redactedValue);
    expect(result.queryParameters['access_token'], redactedValue);
    expect(result.toString(), isNot(contains('secret')));
    expect(result.toString(), isNot(contains('other')));
  });

  test('redacts nested JSON credentials', () {
    expect(
      redactJson({
        'body': {'access_token': 'secret', 'safe': true},
      }),
      {
        'body': {'access_token': redactedValue, 'safe': true},
      },
    );
  });
}
