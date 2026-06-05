import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_source_page.dart';

void main() {
  test('parseCookieSaveUri accepts only urls with a host', () {
    expect(
      parseCookieSaveUri('https://example.test/login')?.host,
      'example.test',
    );
    expect(parseCookieSaveUri('about:blank'), isNull);
    expect(parseCookieSaveUri(''), isNull);
    expect(parseCookieSaveUri('https://example.test/%ZZ'), isNull);
  });

  test('parseComicSourceListPayload accepts valid source entries', () {
    final parsed = parseComicSourceListPayload([
      {
        'key': 'source',
        'name': 'Source',
        'version': '1.0.0',
        'fileName': 'source.js',
        'url': 'https://example.test/source.js',
        'description': 'desc',
      },
    ]);

    expect(parsed, hasLength(1));
    expect(parsed!.single['key'], 'source');
    expect(parsed.single['description'], 'desc');
  });

  test('parseComicSourceListPayload rejects malformed payloads and rows', () {
    expect(parseComicSourceListPayload({'key': 'source'}), isNull);

    final parsed = parseComicSourceListPayload([
      {'key': 'missing-name'},
      'bad-row',
      {
        'key': 'source',
        'name': 'Source',
        'version': '1.0.0',
        'fileName': 'source.js',
        'description': 1,
      },
    ]);

    expect(parsed, hasLength(1));
    expect(parsed!.single.containsKey('description'), isFalse);
  });

  test('decodeComicSourceListPayload handles invalid json safely', () {
    expect(decodeComicSourceListPayload(null), isNull);
    expect(decodeComicSourceListPayload('{bad'), isNull);
    expect(decodeComicSourceListPayload('{"key":"source"}'), isNull);

    final parsed = decodeComicSourceListPayload(
      '[{"key":"source","name":"Source","version":"1.0.0","fileName":"source.js"}]',
    );
    expect(parsed, hasLength(1));
    expect(parsed!.single['key'], 'source');
  });

  test(
    'normalizeComicSourceSettingItem tolerates malformed setting fields',
    () {
      final select = normalizeComicSourceSettingItem({
        'type': 'select',
        'title': 1,
        'default': 2,
        'options': [
          {'value': 2},
          'bad',
        ],
      });

      expect(select, isNotNull);
      expect(select!['title'], '1');
      expect(select['default'], '2');
      expect(select['options'], [
        {'value': '2', 'text': '2'},
      ]);
      expect(normalizeComicSourceSettingOptions(select['options']), [
        {'value': '2', 'text': '2'},
      ]);

      expect(normalizeComicSourceSettingItem({'type': 1}), isNull);
      expect(
        normalizeComicSourceSettingItem({'type': 'select', 'options': []}),
        isNull,
      );
    },
  );

  test('normalizeComicSourceSettingItem returns typed defaults for UI use', () {
    expect(
      normalizeComicSourceSettingItem({
        'type': 'switch',
        'default': 'yes',
      })!['default'],
      isTrue,
    );

    final input = normalizeComicSourceSettingItem({
      'type': 'input',
      'title': null,
      'default': 7,
      'validator': 12,
    });
    expect(input!['title'], '');
    expect(input['default'], '7');
    expect(input.containsKey('validator'), isFalse);

    final callback = normalizeComicSourceSettingItem({
      'type': 'callback',
      'buttonText': 123,
    });
    expect(callback!['buttonText'], '123');
  });

  test('normalizeComicSourceSettingOptions tolerates dynamic list shapes', () {
    expect(
      normalizeComicSourceSettingOptions([
        {'value': 1, 'text': 'One'},
        {'value': 2},
        'bad',
      ]),
      [
        {'value': '1', 'text': 'One'},
        {'value': '2', 'text': '2'},
      ],
    );

    expect(normalizeComicSourceSettingOptions('bad'), isEmpty);
  });

  test('normalizeComicSourceRuntimeSettings tolerates malformed data', () {
    expect(normalizeComicSourceRuntimeSettings('bad'), isEmpty);
    expect(normalizeComicSourceRuntimeSettings({1: true, 'keep': 2}), {
      '1': true,
      'keep': 2,
    });
  });

  test('filterAvailableComicSourceUpdates drops stale source keys', () {
    final filtered = filterAvailableComicSourceUpdates({
      'live': '2.0.0',
      'stale': '3.0.0',
    }, (key) => key == 'live');

    expect(Map.fromEntries(filtered), {'live': '2.0.0'});
  });

  test('removeAvailableUpdates clears manager update state', () {
    final manager = ComicSourceManager();
    manager.removeAvailableUpdates(['test-source-to-remove']);
    addTearDown(() {
      manager.removeAvailableUpdates(['test-source-to-remove']);
    });

    manager.updateAvailableUpdates({'test-source-to-remove': '2.0.0'});

    expect(
      manager.availableUpdates,
      containsPair('test-source-to-remove', '2.0.0'),
    );

    manager.removeAvailableUpdates(['test-source-to-remove']);

    expect(
      manager.availableUpdates,
      isNot(containsPair('test-source-to-remove', '2.0.0')),
    );
  });
}
