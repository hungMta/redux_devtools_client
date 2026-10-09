/// Converts any value into a tree of JSON primitives, maps and lists.
///
/// Never throws: values that cannot be converted become their `toString()`,
/// and a failing `toJson()` becomes an `<error: ...>` string. Keys listed in
/// [redactKeys] (compared lower-case) are replaced with `'<redacted>'`.
Object? toJsonSafe(
  Object? value, {
  Set<String> redactKeys = const {},
  int maxDepth = 64,
}) {
  return _convert(value, redactKeys, maxDepth, 0);
}

const kDefaultRedactKeys = {
  'password',
  'newpassword',
  'oldpassword',
  'pin',
  'otp',
  'token',
  'accesstoken',
  'refreshtoken',
  'idtoken',
  'jwt',
  'authorization',
  'secret',
  'tradingtoken',
};

Object? _convert(Object? value, Set<String> redact, int maxDepth, int depth) {
  if (value == null || value is bool || value is String) return value;
  if (value is num) return value.isFinite ? value : value.toString();
  if (depth >= maxDepth) return '<max depth>';
  try {
    if (value is Map) {
      final result = <String, Object?>{};
      value.forEach((key, v) {
        final k = key is Enum ? key.name : key.toString();
        result[k] = redact.contains(k.toLowerCase())
            ? '<redacted>'
            : _convert(v, redact, maxDepth, depth + 1);
      });
      return result;
    }
    if (value is Iterable) {
      return [for (final v in value) _convert(v, redact, maxDepth, depth + 1)];
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is Duration) return value.toString();
    if (value is Enum) return value.name;
    final json = _tryToJson(value);
    if (!identical(json, _noToJson)) {
      if (identical(json, value)) return value.toString();
      return _convert(json, redact, maxDepth, depth + 1);
    }
    return value.toString();
  } catch (e) {
    return '<error: $e>';
  }
}

const _noToJson = Object();

Object? _tryToJson(Object value) {
  try {
    return (value as dynamic).toJson();
  } on NoSuchMethodError {
    return _noToJson;
  }
}
