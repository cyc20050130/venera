import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

void main() {
  test('compareSemVer tolerates short or nonnumeric version strings', () {
    expect(compareSemVer('1.2.0', '1.1.9'), isTrue);
    expect(compareSemVer('1.2', '1.2.0'), isFalse);
    expect(compareSemVer('bad', '0.0.0'), isFalse);
    expect(compareSemVer('0.0.1', 'bad'), isTrue);
  });

  test('compareSemVer preserves hotfix suffix ordering', () {
    expect(compareSemVer('1.0.0-hotfix', '1.0.0'), isTrue);
    expect(compareSemVer('1.0.0', '1.0.0-hotfix'), isFalse);
  });

  test('extractComicSourceClassName accepts indented class declarations', () {
    expect(
      extractComicSourceClassName(
        '  class DemoSource extends ComicSource {\n  }\n',
      ),
      'DemoSource',
    );
    expect(
      extractComicSourceClassName('class NotASource extends SomethingElse {}'),
      isNull,
    );
  });

  test('category format detection tolerates empty categories', () {
    expect(isNewCategoryFormatList(null), isTrue);
    expect(isNewCategoryFormatList([]), isTrue);
    expect(
      isNewCategoryFormatList([
        {'label': 'tag'},
      ]),
      isTrue,
    );
    expect(isNewCategoryFormatList(['tag']), isFalse);
  });

  test('parseComicIdMatch ignores malformed optional regex values', () {
    expect(parseComicIdMatch(null), isNull);
    expect(parseComicIdMatch(''), isNull);
    expect(parseComicIdMatch('['), isNull);

    final matcher = parseComicIdMatch(r'^comic-\d+$');
    expect(matcher, isNotNull);
    expect(matcher!.hasMatch('comic-42'), isTrue);
    expect(matcher.hasMatch('bad'), isFalse);
  });
}
