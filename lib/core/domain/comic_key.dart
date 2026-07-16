import 'dart:convert';

/// Stable identity for a comic across processes, databases and backups.
///
/// Dart's [Object.hashCode] is intentionally not used for persistence. A
/// comic is identified by the source's stable key and the source-local comic
/// id instead.
final class ComicKey {
  const ComicKey({required this.sourceKey, required this.comicId});

  factory ComicKey.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('ComicKey must be a JSON object');
    }
    final sourceKey = value['sourceKey'];
    final comicId = value['comicId'];
    if (sourceKey is! String || comicId is! String) {
      throw const FormatException(
        'ComicKey.sourceKey and ComicKey.comicId must be strings',
      );
    }
    return ComicKey(sourceKey: sourceKey, comicId: comicId);
  }

  /// Decodes the collision-free representation returned by [storageKey].
  factory ComicKey.fromStorageKey(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! List || decoded.length != 2) {
      throw const FormatException('Invalid ComicKey storage key');
    }
    final sourceKey = decoded[0];
    final comicId = decoded[1];
    if (sourceKey is! String || comicId is! String) {
      throw const FormatException('Invalid ComicKey storage key');
    }
    return ComicKey(sourceKey: sourceKey, comicId: comicId);
  }

  final String sourceKey;

  final String comicId;

  Map<String, String> toJson() => {'sourceKey': sourceKey, 'comicId': comicId};

  /// Collision-free value suitable for in-memory maps and text columns.
  ///
  /// JSON encoding is used instead of joining the components with a delimiter
  /// because source keys and comic ids are controlled by external sources.
  String get storageKey => jsonEncode([sourceKey, comicId]);

  @override
  bool operator ==(Object other) =>
      other is ComicKey &&
      other.sourceKey == sourceKey &&
      other.comicId == comicId;

  @override
  int get hashCode => Object.hash(sourceKey, comicId);

  @override
  String toString() => '$sourceKey@$comicId';
}
