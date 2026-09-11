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
  EditorTextContent({required this.text, required this.hasUtf8Bom});

  final String text;
  final bool hasUtf8Bom;
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

/// A verified CAS object plus the decoded document and its conflict baseline.
final class PreparedEditorFile {
  PreparedEditorFile({
    required this.file,
    required this.remoteNode,
    required this.text,
    required this.hasUtf8Bom,
    required this.baseline,
    required List<int> bytes,
  }) : bytes = List.unmodifiable(bytes);

  final File file;
  final CloudNode remoteNode;
  final String text;
  final bool hasUtf8Bom;
  final EditorSaveBaseline baseline;
  final List<int> bytes;

  String get name => remoteNode.name;

  String get path => baseline.path;

  int get encodedBytes => bytes.length;

  /// Re-checks the immutable prepared bytes. This is useful for test fakes and
  /// keeps the actual cloud hash calculation next to the preparation model.
  String get contentHash => calculateCloudHash(bytes);
}
