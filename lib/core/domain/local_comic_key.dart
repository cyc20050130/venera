import 'dart:convert';

/// Stable identity used by local comics whose persisted type is not a source
/// key and may therefore not be represented by [ComicKey].
final class LocalComicKey {
  const LocalComicKey({required this.comicType, required this.comicId});

  factory LocalComicKey.fromStorageKey(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! List || decoded.length != 2) {
      throw const FormatException('Invalid LocalComicKey storage key');
    }
    final comicType = decoded[0];
    final comicId = decoded[1];
    if (comicType is! String || comicId is! String) {
      throw const FormatException('Invalid LocalComicKey storage key');
    }
    return LocalComicKey(comicType: comicType, comicId: comicId);
  }

  final String comicType;
  final String comicId;

  String get storageKey => jsonEncode([comicType, comicId]);

  @override
  bool operator ==(Object other) =>
      other is LocalComicKey &&
      other.comicType == comicType &&
      other.comicId == comicId;

  @override
  int get hashCode => Object.hash(comicType, comicId);

  @override
  String toString() => '$comicType@$comicId';
}
