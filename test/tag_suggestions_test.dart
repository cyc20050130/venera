import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/tag_suggestions.dart';
import 'package:venera/utils/tags_translation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    appdata.settings['language'] = 'zh-CN';
    await TagsTranslation.readData();
    TagSuggestions.debugClearCache();
  });

  test('matches tag prefixes and last words without scanning UI state', () {
    expect(
      TagSuggestions.matches('age', 'age progression', 'age progression'),
      isTrue,
    );
    expect(
      TagSuggestions.matches('progression', 'age progression', ''),
      isTrue,
    );
    expect(TagSuggestions.matches('', 'age progression', ''), isFalse);
    expect(TagSuggestions.matches('missing', 'age progression', ''), isFalse);
  });

  test('returns cached results for repeated tag suggestion queries', () {
    final first = TagSuggestions.find('age', limit: 5);
    final second = TagSuggestions.find('age', limit: 5);

    expect(first, isNotEmpty);
    expect(identical(first, second), isTrue);
  });

  test(
    'invalidates cached tag suggestions after translations reload',
    () async {
      final first = TagSuggestions.find('age', limit: 5);

      await TagsTranslation.readData();
      final second = TagSuggestions.find('age', limit: 5);

      expect(first, isNotEmpty);
      expect(second, isNotEmpty);
      expect(identical(first, second), isFalse);
    },
  );

  test('respects the requested suggestion limit', () {
    final suggestions = TagSuggestions.find('age', limit: 2);

    expect(suggestions.length, lessThanOrEqualTo(2));
  });

  test('notifies listeners when translations become ready', () async {
    final versions = <int>[];
    void listener() {
      versions.add(TagsTranslation.readyNotifier.value);
    }

    TagsTranslation.readyNotifier.addListener(listener);
    addTearDown(() {
      TagsTranslation.readyNotifier.removeListener(listener);
    });

    await TagsTranslation.readData();

    expect(versions, isNotEmpty);
    expect(versions.last, TagsTranslation.dataVersion);
  });
}
