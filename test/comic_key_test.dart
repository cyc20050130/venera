import 'package:flutter_test/flutter_test.dart';
import 'package:venera/core/domain/comic_key.dart';

void main() {
  test('ComicKey round-trips through JSON and storage representation', () {
    const key = ComicKey(sourceKey: 'source@one', comicId: 'comic/@/42');

    expect(ComicKey.fromJson(key.toJson()), key);
    expect(ComicKey.fromStorageKey(key.storageKey), key);
  });

  test('ComicKey storage representation cannot collide on delimiters', () {
    const first = ComicKey(sourceKey: 'a@b', comicId: 'c');
    const second = ComicKey(sourceKey: 'a', comicId: 'b@c');

    expect(first.storageKey, isNot(second.storageKey));
    expect(first, isNot(second));
  });

  test('ComicKey rejects malformed persisted values', () {
    expect(
      () => ComicKey.fromJson({'sourceKey': 'source'}),
      throwsFormatException,
    );
    expect(() => ComicKey.fromStorageKey('["source"]'), throwsFormatException);
  });
}
