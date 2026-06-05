import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/pages/search_result_page.dart';

void main() {
  test('decodeSearchMultiSelectValue accepts only string list values', () {
    expect(decodeSearchMultiSelectValue('["a","b"]'), ['a', 'b']);
    expect(decodeSearchMultiSelectValue('["a",1,null,"b"]'), ['a', 'b']);
    expect(decodeSearchMultiSelectValue('"a"'), isEmpty);
    expect(decodeSearchMultiSelectValue('{bad'), isEmpty);
  });

  test('search result source error handles missing or unsupported sources', () {
    expect(
      resolveSearchResultSourceError(
        sourceKey: 'missing-source',
        searchPageData: null,
      ),
      contains('missing-source'),
    );
    expect(
      resolveSearchResultSourceError(
        sourceKey: 'no-search',
        searchPageData: const SearchPageData(null, null, null),
      ),
      contains('no-search'),
    );
    expect(
      resolveSearchResultSourceError(
        sourceKey: 'ok',
        searchPageData: SearchPageData(
          null,
          (_, _, _) async => throw 'unused',
          null,
        ),
      ),
      isNull,
    );
  });

  test('search page resolves data only for a live source target', () {
    expect(resolveSearchPageData(sourceKey: '', searchPageData: null), isNull);
    expect(
      resolveSearchPageData(sourceKey: 'missing', searchPageData: null),
      isNull,
    );

    final data = SearchPageData(null, (_, _, _) async => throw 'unused', null);
    expect(
      resolveSearchPageData(sourceKey: 'searchable', searchPageData: data),
      same(data),
    );
  });

  test('search settings options resolve only for searchable sources', () {
    expect(
      resolveSearchSettingsOptions(sourceKey: 'missing', searchPageData: null),
      isNull,
    );
    expect(
      resolveSearchSettingsOptions(
        sourceKey: 'no-search',
        searchPageData: const SearchPageData(null, null, null),
      ),
      isNull,
    );
    expect(
      resolveSearchSettingsOptions(
        sourceKey: 'searchable-without-options',
        searchPageData: SearchPageData(
          null,
          (_, _, _) async => throw 'unused',
          null,
        ),
      ),
      isEmpty,
    );
    final option = SearchOptions(
      LinkedHashMap.of({'a': 'A'}),
      'label',
      'select',
      'a',
    );
    expect(
      resolveSearchSettingsOptions(
        sourceKey: 'searchable',
        searchPageData: SearchPageData(
          [option],
          (_, _, _) async => throw 'unused',
          null,
        ),
      ),
      [option],
    );
  });

  test('search option parser skips malformed source rows safely', () {
    expect(normalizeSearchOptionsItem('bad'), isNull);
    expect(
      normalizeSearchOptionsItem({
        'label': 'Empty',
        'options': ['bad'],
      }),
      isNull,
    );

    final option = normalizeSearchOptionsItem({
      'label': 42,
      'type': 'unsupported',
      'default': ['a', 1],
      'options': ['a-A', 'b-Name-With-Dash', '-missing-key', 'bad', 7, null],
    });

    expect(option, isNotNull);
    expect(option!.label, '42');
    expect(option.type, 'select');
    expect(option.defaultVal, '["a",1]');
    expect(option.options, {'a': 'A', 'b': 'Name-With-Dash'});
  });

  test('search option parser keeps supported option types', () {
    expect(
      normalizeSearchOptionsItem({
        'type': 'multi-select',
        'options': ['a-A'],
      })!.type,
      'multi-select',
    );
    expect(
      normalizeSearchOptionsItem({
        'type': 'dropdown',
        'options': ['a-A'],
      })!.type,
      'dropdown',
    );
  });
}
