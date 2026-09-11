import 'dart:convert';

import 'package:easy_cloud/features/editor/domain/editor_file.dart';
import 'package:easy_cloud/features/editor/domain/editor_save.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes only the supported final extension', () {
    final supported = [
      'note.txt',
      'README.MD',
      'data.Json',
      'layout.xml',
      'config.yaml',
      'config.YML',
      'table.csv',
      'server.log',
      'app.ini',
      'nginx.conf',
    ];
    for (final name in supported) {
      expect(isEditableTextFile(name), isTrue, reason: name);
    }

    for (final name in [
      '.txt',
      '.env.txt',
      'README',
      'README.',
      'archive.tar.gz',
      'photo.PNG',
      'note.conf.bak',
    ]) {
      expect(isEditableTextFile(name), isFalse, reason: name);
    }
  });

  test('decodes and re-encodes a BOM without changing text', () {
    final bytes = <int>[...utf8.encode('one\r\ntwo\n'), 0xef, 0xbb, 0xbf];
    final content = decodeEditorUtf8([
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode('one\r\ntwo\n'),
    ]);

    expect(content.hasUtf8Bom, isTrue);
    expect(content.text, 'one\r\ntwo\n');
    expect(encodeEditorUtf8(content.text, hasUtf8Bom: content.hasUtf8Bom), [
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode('one\r\ntwo\n'),
    ]);
    expect(bytes.length, greaterThan(content.text.length));
  });

  test('decodes strict UTF-8 and keeps Unicode byte length distinct', () {
    final text = 'Привет, cloud ☁️';
    final bytes = utf8.encode(text);
    expect(bytes.length, greaterThan(text.length));
    expect(decodeEditorUtf8(bytes).text, text);
    expect(encodeEditorUtf8(text, hasUtf8Bom: false), bytes);

    expect(
      () => decodeEditorUtf8(const [0xc3, 0x28]),
      throwsA(
        isA<EditorPreparationFailure>().having(
          (failure) => failure.type,
          'type',
          EditorPreparationFailureType.malformedUtf8,
        ),
      ),
    );
  });

  test('editor byte limit counts the BOM', () {
    final exact = List<int>.filled(editorMaxBytes, 0x61, growable: false);
    final plusOne = <int>[
      0xef,
      0xbb,
      0xbf,
      ...List<int>.filled(editorMaxBytes - 2, 0x61, growable: false),
    ];

    expect(exact.length, editorMaxBytes);
    expect(plusOne.length, editorMaxBytes + 1);
    expect(decodeEditorUtf8(exact).hasUtf8Bom, isFalse);
    expect(decodeEditorUtf8(plusOne).hasUtf8Bom, isTrue);
  });
}
