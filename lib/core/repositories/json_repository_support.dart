import 'dart:convert';

/// Returns a detached, deeply immutable JSON value.
///
/// Repository records never retain mutable maps supplied by callers. This
/// prevents an in-memory mutation from diverging from the value persisted in
/// SQLite.
Object? normalizeRepositoryJson(Object? value, {required String context}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonEncode(value));
  } catch (error) {
    throw FormatException('$context must be valid JSON', error);
  }
  return _freezeJson(decoded, context: context);
}

Object? decodeRepositoryJson(String encoded, {required String context}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(encoded);
  } catch (error) {
    throw FormatException('$context must be valid JSON', error);
  }
  return _freezeJson(decoded, context: context);
}

Map<String, Object?> decodeRepositoryJsonObject(
  String encoded, {
  required String context,
}) {
  final decoded = decodeRepositoryJson(encoded, context: context);
  if (decoded is! Map<String, Object?>) {
    throw FormatException('$context must be a JSON object');
  }
  return decoded;
}

Map<String, Object?> normalizeRepositoryJsonObject(
  Object? value, {
  required String context,
}) {
  final normalized = normalizeRepositoryJson(value, context: context);
  if (normalized is! Map<String, Object?>) {
    throw FormatException('$context must be a JSON object');
  }
  return normalized;
}

String encodeRepositoryJson(Object? value, {required String context}) {
  final normalized = normalizeRepositoryJson(value, context: context);
  return jsonEncode(normalized);
}

Object? _freezeJson(Object? value, {required String context}) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((entry) => _freezeJson(entry, context: context)),
    );
  }
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw FormatException('$context contains a non-string key');
      }
      result[key] = _freezeJson(entry.value, context: context);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  throw FormatException('$context contains an unsupported value');
}
