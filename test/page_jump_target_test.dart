import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

void main() {
  test('PageJumpTarget parses legacy search strings safely', () {
    final missingPayload = PageJumpTarget.parse('source', 'search');
    expect(missingPayload.page, 'search');
    expect(missingPayload.attributes?['text'], '');

    final emptyPayload = PageJumpTarget.parse('source', 'search:');
    expect(emptyPayload.page, 'search');
    expect(emptyPayload.attributes?['text'], '');
  });

  test('PageJumpTarget preserves category params after first at sign', () {
    final target = PageJumpTarget.parse(
      'source',
      'category:artist@name@with-at',
    );

    expect(target.page, 'category');
    expect(target.attributes?['category'], 'artist');
    expect(target.attributes?['param'], 'name@with-at');
  });

  test('PageJumpTarget keeps unknown legacy strings as page names', () {
    final target = PageJumpTarget.parse('source', 'customPage');

    expect(target.page, 'customPage');
    expect(target.attributes, isNull);
  });
}
