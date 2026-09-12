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

  test('falls back to Windows-1251 and round-trips Cyrillic text', () {
    final bytes = <int>[0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2, 0x21];
    final content = decodeEditorText(bytes);

    expect(content.encoding, EditorTextEncoding.windows1251);
    expect(content.hasUtf8Bom, isFalse);
    expect(content.text, 'Привет!');
    expect(encodeWindows1251(content.text), bytes);
  });

  test('valid UTF-8 wins and unsupported Windows-1251 text is rejected', () {
    final content = decodeEditorText(utf8.encode('Привет'));
    expect(content.encoding, EditorTextEncoding.utf8);
    expect(() => encodeWindows1251('cloud ☁'), throwsFormatException);
    expect(
      () => decodeEditorText(const [0x98]),
      throwsA(isA<EditorPreparationFailure>()),
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
