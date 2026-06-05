import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/categories_page.dart';

void main() {
  test('random category start bound includes the last valid window', () {
    expect(randomCategoryStartBound(itemCount: 10, randomNumber: 4), 7);
    expect(randomCategoryStartBound(itemCount: 4, randomNumber: 4), 0);
    expect(randomCategoryStartBound(itemCount: 0, randomNumber: 1), 0);
    expect(randomCategoryStartBound(itemCount: 4, randomNumber: 0), 0);
  });

  test('enabled category pages keep only currently available categories', () {
    expect(
      normalizeEnabledCategoryPages(
        configuredCategories: ['a', 'stale', 'b', 'a'],
        availableCategories: ['a', 'b'],
      ),
      ['a', 'b', 'a'],
    );
    expect(
      normalizeEnabledCategoryPages(
        configuredCategories: ['stale'],
        availableCategories: ['a'],
      ),
      isEmpty,
    );
  });

  test('dynamic category items skip malformed loader rows safely', () {
    expect(normalizeDynamicCategoryItems('bad', 'source'), isEmpty);

    final items = normalizeDynamicCategoryItems([
      {'label': 'tag', 'target': 'search:tag'},
      {'label': 42, 'target': 'category:artist@param'},
      {'label': null, 'target': 'search:bad'},
      'bad-row',
    ], 'source');

    expect(items, hasLength(2));
    expect(items.first.label, 'tag');
    expect(items.first.target.page, 'search');
    expect(items.first.target.attributes?['text'], 'tag');
    expect(items.last.label, '42');
    expect(items.last.target.page, 'category');
    expect(items.last.target.attributes?['category'], 'artist');
    expect(items.last.target.attributes?['param'], 'param');
  });

  test('legacy category helpers normalize malformed source rows safely', () {
    expect(normalizeLegacyCategoryTags('bad'), isEmpty);
    expect(normalizeLegacyCategoryTags(['tag', 2, null, '']), ['tag', '2']);

    expect(normalizeCategoryRandomNumber(3), 3);
    expect(normalizeCategoryRandomNumber('4'), 4);
    expect(normalizeCategoryRandomNumber('bad'), 1);
    expect(normalizeCategoryRandomNumber(null), 1);
  });
}
