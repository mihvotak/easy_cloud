import 'dart:convert';
import 'dart:io';

import '../../browser/domain/cloud_node.dart';
import '../../../cloud_mail/probe/cloud_hash.dart';
import 'editor_save.dart';

/// Extensions supported by the internal editor.
///
/// The comparison is deliberately performed against the final extension only;
/// hidden files and names without an extension are not text-editor files.
const editableTextExtensions = <String>{
  'txt',
  'md',
  'json',
  'xml',
  'yaml',
  'yml',
  'csv',
  'log',
  'ini',
  'conf',
};

/// Flutter's EditableText lays out the complete document and becomes unstable
/// with multi-megabyte values on Android. Keep the 10 MiB save protocol limit,
/// but refuse unsafe inline rendering before allocating the editor widget.
const inlineEditorMaxBytes = 2 * 1024 * 1024;

/// Returns whether [name] is a supported, non-hidden text file name.
bool isEditableTextFile(String name) {
  if (name.isEmpty || name.startsWith('.')) return false;
  final separator = name.lastIndexOf('.');
  if (separator <= 0 || separator == name.length - 1) return false;
  return editableTextExtensions.contains(
    name.substring(separator + 1).toLowerCase(),
  );
}

enum EditorPreparationFailureType {
  cancelled,
  oversize,
  malformedUtf8,
  integrity,
  invalidResponse,
  notFound,
  disk,
  service,
}

enum EditorTextEncoding { utf8, windows1251 }

/// Safe failure raised while preparing a verified cloud object for editing.
final class EditorPreparationFailure implements Exception {
  const EditorPreparationFailure(this.type, this.message);

  final EditorPreparationFailureType type;
  final String message;

  bool get isCancelled => type == EditorPreparationFailureType.cancelled;

  bool get isQuiet => isCancelled;

  @override
  String toString() => message;
}

/// Decoded editor content and the BOM bit needed to reproduce its bytes.
final class EditorTextContent {
  EditorTextContent({
    required this.text,
    required this.hasUtf8Bom,
    this.encoding = EditorTextEncoding.utf8,
  });

  final String text;
  final bool hasUtf8Bom;
  final EditorTextEncoding encoding;
}

/// Decodes strict UTF-8 first and falls back to Windows-1251 only when UTF-8
/// is malformed. Valid UTF-8 therefore always wins over the legacy encoding.
EditorTextContent decodeEditorText(List<int> bytes) {
  try {
    return decodeEditorUtf8(bytes);
  } on EditorPreparationFailure catch (failure) {
    if (failure.type != EditorPreparationFailureType.malformedUtf8) rethrow;
    try {
      return EditorTextContent(
        text: decodeWindows1251(bytes),
        hasUtf8Bom: false,
        encoding: EditorTextEncoding.windows1251,
      );
    } on FormatException {
      throw const EditorPreparationFailure(
        EditorPreparationFailureType.malformedUtf8,
        'Файл не удалось распознать как UTF-8 или Windows-1251.',
      );
    }
  }
}

/// Strictly decodes UTF-8 editor bytes without changing line endings or any
/// other characters. A leading UTF-8 BOM is metadata, not editor text.
EditorTextContent decodeEditorUtf8(List<int> bytes) {
  final hasBom =
      bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
  final content = hasBom ? bytes.sublist(3) : bytes;
  try {
    return EditorTextContent(
      text: utf8.decode(content, allowMalformed: false),
      hasUtf8Bom: hasBom,
    );
  } on FormatException {
    throw const EditorPreparationFailure(
      EditorPreparationFailureType.malformedUtf8,
      'Файл содержит некорректный UTF-8.',
    );
  }
}

/// Encodes editor text exactly as entered, adding the original BOM only when
/// the opened file had one. No newline conversion or formatting is performed.
List<int> encodeEditorUtf8(String text, {required bool hasUtf8Bom}) {
  final body = utf8.encode(text);
  if (!hasUtf8Bom) return body;
  return <int>[0xef, 0xbb, 0xbf, ...body];
}

String decodeWindows1251(List<int> bytes) {
  final codePoints = <int>[];
  for (final byte in bytes) {
    if (byte < 0 || byte > 0xff || byte == 0x98) {
      throw const FormatException('Invalid Windows-1251 byte.');
    }
    codePoints.add(byte < 0x80 ? byte : _windows1251CodePoints[byte - 0x80]);
  }
  return String.fromCharCodes(codePoints);
}

List<int> encodeWindows1251(String text) {
  final result = <int>[];
  for (final rune in text.runes) {
    if (rune < 0x80) {
      result.add(rune);
      continue;
    }
    final byte = _windows1251Bytes[rune];
    if (byte == null) {
      throw const FormatException(
        'Text contains characters unavailable in Windows-1251.',
      );
    }
    result.add(byte);
  }
  return result;
}

const _windows1251CodePoints = <int>[
  0x0402,
  0x0403,
  0x201a,
  0x0453,
  0x201e,
  0x2026,
  0x2020,
  0x2021,
  0x20ac,
  0x2030,
  0x0409,
  0x2039,
  0x040a,
  0x040c,
  0x040b,
  0x040f,
  0x0452,
  0x2018,
  0x2019,
  0x201c,
  0x201d,
  0x2022,
  0x2013,
  0x2014,
  0xfffd,
  0x2122,
  0x0459,
  0x203a,
  0x045a,
  0x045c,
  0x045b,
  0x045f,
  0x00a0,
  0x040e,
  0x045e,
  0x0408,
  0x00a4,
  0x0490,
  0x00a6,
  0x00a7,
  0x0401,
  0x00a9,
  0x0404,
  0x00ab,
  0x00ac,
  0x00ad,
  0x00ae,
  0x0407,
  0x00b0,
  0x00b1,
  0x0406,
  0x0456,
  0x0491,
  0x00b5,
  0x00b6,
  0x00b7,
  0x0451,
  0x2116,
  0x0454,
  0x00bb,
  0x0458,
  0x0405,
  0x0455,
  0x0457,
  0x0410,
  0x0411,
  0x0412,
  0x0413,
  0x0414,
  0x0415,
  0x0416,
  0x0417,
  0x0418,
  0x0419,
  0x041a,
  0x041b,
  0x041c,
  0x041d,
  0x041e,
  0x041f,
  0x0420,
  0x0421,
  0x0422,
  0x0423,
  0x0424,
  0x0425,
  0x0426,
  0x0427,
  0x0428,
  0x0429,
  0x042a,
  0x042b,
  0x042c,
  0x042d,
  0x042e,
  0x042f,
  0x0430,
  0x0431,
  0x0432,
  0x0433,
  0x0434,
  0x0435,
  0x0436,
  0x0437,
  0x0438,
  0x0439,
  0x043a,
  0x043b,
  0x043c,
  0x043d,
  0x043e,
  0x043f,
  0x0440,
  0x0441,
  0x0442,
  0x0443,
  0x0444,
  0x0445,
  0x0446,
  0x0447,
  0x0448,
  0x0449,
  0x044a,
  0x044b,
  0x044c,
  0x044d,
  0x044e,
  0x044f,
];

final _windows1251Bytes = <int, int>{
  for (var index = 0; index < _windows1251CodePoints.length; index++)
    if (index != 0x18) _windows1251CodePoints[index]: index + 0x80,
};

/// A verified CAS object plus the decoded document and its conflict baseline.
final class PreparedEditorFile {
  PreparedEditorFile({
    required this.file,
    required this.remoteNode,
    required this.text,
    required this.hasUtf8Bom,
    this.encoding = EditorTextEncoding.utf8,
    required this.baseline,
    required List<int> bytes,
  }) : bytes = List.unmodifiable(bytes);

  final File file;
  final CloudNode remoteNode;
  final String text;
  final bool hasUtf8Bom;
  final EditorTextEncoding encoding;
  final EditorSaveBaseline baseline;
  final List<int> bytes;

  String get name => remoteNode.name;

  String get path => baseline.path;

  int get encodedBytes => bytes.length;

  /// Re-checks the immutable prepared bytes. This is useful for test fakes and
  /// keeps the actual cloud hash calculation next to the preparation model.
  String get contentHash => calculateCloudHash(bytes);
}
