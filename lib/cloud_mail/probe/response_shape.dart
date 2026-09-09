import 'dart:convert';

String responseShape(List<int> bytes, {String? contentType}) {
  if (bytes.isEmpty) return 'empty';

  final normalizedContentType = contentType?.toLowerCase();
  final looksJson = normalizedContentType?.contains('json') ?? false;
  if (looksJson || bytes.first == 0x7b || bytes.first == 0x5b) {
    try {
      return jsonShape(jsonDecode(utf8.decode(bytes)));
    } on FormatException {
      return 'invalid-json(${bytes.length} bytes)';
    }
  }
  if (normalizedContentType == 'application/octet-stream') {
    return 'binary(${bytes.length} bytes)';
  }
  if (_looksText(bytes)) return 'text(${bytes.length} bytes)';
  return 'binary(${bytes.length} bytes)';
}

String jsonShape(Object? value, {int depth = 0}) {
  if (value == null) return 'null';
  if (value is String) return 'string';
  if (value is num) return 'number';
  if (value is bool) return 'boolean';
  if (depth >= 3) return value is List ? 'array' : 'object';

  if (value is List) {
    if (value.isEmpty) return 'array(0)';
    return 'array(${value.length})<${jsonShape(value.first, depth: depth + 1)}>';
  }
  if (value is Map) {
    final entries = value.entries
        .take(20)
        .map(
          (entry) => '${entry.key}:${jsonShape(entry.value, depth: depth + 1)}',
        );
    final suffix = value.length > 20 ? ',...' : '';
    return 'object{${entries.join(',')}$suffix}';
  }
  return value.runtimeType.toString();
}

bool _looksText(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}
