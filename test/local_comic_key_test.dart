import 'package:flutter_test/flutter_test.dart';
import 'package:venera/core/domain/local_comic_key.dart';

void main() {
  test('LocalComicKey storage representation is collision free', () {
    const first = LocalComicKey(comicType: 'a@b', comicId: 'c');
    const second = LocalComicKey(comicType: 'a', comicId: 'b@c');

    expect(first.storageKey, isNot(second.storageKey));
    expect(LocalComicKey.fromStorageKey(first.storageKey), first);
  });

  test('LocalComicKey rejects malformed storage values', () {
    expect(
      () => LocalComicKey.fromStorageKey('["only-one"]'),
      throwsFormatException,
    );
  });
}
