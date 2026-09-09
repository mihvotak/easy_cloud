const redactedValue = '[REDACTED]';

const _sensitiveKeys = <String>{
  'access_token',
  'authorization',
  'cookie',
  'csrf',
  'csrf_token',
  'password',
  'refresh_token',
  'token',
  'tsa_token',
  'x-csrf-token',
};

bool isSensitiveKey(String key) {
  final normalized = key.trim().toLowerCase().replaceAll('-', '_');
  return _sensitiveKeys.contains(key.trim().toLowerCase()) ||
      _sensitiveKeys.contains(normalized);
}

Map<String, String> redactFields(Map<String, String> values) => {
  for (final entry in values.entries)
    entry.key: isSensitiveKey(entry.key) ? redactedValue : entry.value,
};

Uri redactUri(Uri uri) {
  if (!uri.hasQuery) return uri;

  final safeQuery = <String, List<String>>{};
  for (final entry in uri.queryParametersAll.entries) {
    safeQuery[entry.key] = isSensitiveKey(entry.key)
        ? const [redactedValue]
        : entry.value;
  }
  return uri.replace(queryParameters: safeQuery);
}

Object? redactJson(Object? value) {
  if (value is List) return value.map(redactJson).toList(growable: false);
  if (value is! Map) return value;

  return <String, Object?>{
    for (final entry in value.entries)
      entry.key.toString(): isSensitiveKey(entry.key.toString())
          ? redactedValue
          : redactJson(entry.value),
  };
}
