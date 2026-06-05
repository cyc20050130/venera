import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/category_comics_page.dart';

void main() {
  test('category options load applies only to the live latest request', () {
    expect(
      shouldApplyCategoryOptionsLoad(
        mounted: true,
        requestId: 2,
        currentRequestId: 2,
      ),
      isTrue,
    );
    expect(
      shouldApplyCategoryOptionsLoad(
        mounted: false,
        requestId: 2,
        currentRequestId: 2,
      ),
      isFalse,
    );
    expect(
      shouldApplyCategoryOptionsLoad(
        mounted: true,
        requestId: 1,
        currentRequestId: 2,
      ),
      isFalse,
    );
  });

  test('normalizeCategoryOptionsValue tolerates empty and changed options', () {
    final options = [
      CategoryComicsOptions(
        '',
        LinkedHashMap.of({'a': 'A', 'b': 'B'}),
        const [],
        null,
      ),
      CategoryComicsOptions(
        '',
        LinkedHashMap<String, String>(),
        const [],
        null,
      ),
      CategoryComicsOptions('', LinkedHashMap.of({'x': 'X'}), const [], null),
    ];

    expect(normalizeCategoryOptionsValue(['b', 'stale', 'missing'], options), [
      'b',
      '',
      'x',
    ]);
  });

  test('category option parser skips malformed source rows safely', () {
    final parsed = parseCategoryOptionEntries([
      'a-A',
      'b-Name-With-Dash',
      '-missing-key',
      'bad',
      7,
      null,
    ]);

    expect(parsed, {'a': 'A', 'b': 'Name-With-Dash'});
  });

  test('category option item normalizes dynamic source fields', () {
    expect(normalizeCategoryComicsOptionsItem('bad'), isNull);
    expect(
      normalizeCategoryComicsOptionsItem({
        'label': 'Empty',
        'options': ['bad'],
      }),
      isNull,
    );

    final option = normalizeCategoryComicsOptionsItem({
      'label': 42,
      'options': ['a-A', 'b-B'],
      'notShowWhen': ['hidden', 1, null],
      'showWhen': ['visible', 2, null],
    });

    expect(option, isNotNull);
    expect(option!.label, '42');
    expect(option.options, {'a': 'A', 'b': 'B'});
    expect(option.notShowWhen, ['hidden', '1']);
    expect(option.showWhen, ['visible', '2']);
  });

  test('category options load exception message is stable', () {
    expect(categoryOptionsLoadExceptionMessage('boom'), 'boom');
    expect(
      categoryOptionsLoadExceptionMessage(Exception('boom')),
      contains('boom'),
    );
  });
}
