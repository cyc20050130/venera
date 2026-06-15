import 'package:venera/foundation/global_state.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/tags_translation.dart';

class TagSuggestions {
  TagSuggestions._();

  static final Map<_SuggestionQuery, List<Pair<String, TranslationType>>>
  _cache = {};

  static int _entryVersion = -1;
  static List<_TagSuggestionEntry> _entries = const [];

  static List<Pair<String, TranslationType>> find(
    String text, {
    required int limit,
  }) {
    if (text.removeAllBlank == "") {
      return const [];
    }
    if (!TagsTranslation.isReady) {
      return const [];
    }
    _ensureEntries();
    final query = _SuggestionQuery(TagsTranslation.dataVersion, text, limit);
    final cached = _cache[query];
    if (cached != null) {
      return cached;
    }

    final result = <Pair<String, TranslationType>>[];
    for (final entry in _entries) {
      if (result.length >= limit) {
        break;
      }
      if (entry.matches(text)) {
        result.add(Pair(entry.key, entry.type));
      }
    }
    final frozen = List<Pair<String, TranslationType>>.unmodifiable(result);
    _cache[query] = frozen;
    return frozen;
  }

  static bool matches(String text, String key, String value) {
    if (text.removeAllBlank == "") {
      return false;
    }
    if (key.length >= text.length && key.substring(0, text.length) == text) {
      return true;
    }
    if (key.contains(" ")) {
      final lastWord = key.split(" ").last;
      if (lastWord.length >= text.length &&
          lastWord.substring(0, text.length) == text) {
        return true;
      }
    }
    return value.length >= text.length && value.contains(text);
  }

  static void debugClearCache() {
    _cache.clear();
    _entryVersion = -1;
    _entries = const [];
  }

  static void _ensureEntries() {
    final version = TagsTranslation.dataVersion;
    if (_entryVersion == version) {
      return;
    }
    _entryVersion = version;
    _cache.clear();
    _entries = List<_TagSuggestionEntry>.unmodifiable([
      ..._entriesFor(TagsTranslation.femaleTags, TranslationType.female),
      ..._entriesFor(TagsTranslation.maleTags, TranslationType.male),
      ..._entriesFor(TagsTranslation.parodyTags, TranslationType.parody),
      ..._entriesFor(
        TagsTranslation.characterTranslations,
        TranslationType.character,
      ),
      ..._entriesFor(TagsTranslation.otherTags, TranslationType.other),
      ..._entriesFor(TagsTranslation.mixedTags, TranslationType.mixed),
      ..._entriesFor(
        TagsTranslation.languageTranslations,
        TranslationType.language,
      ),
      ..._entriesFor(TagsTranslation.artistTags, TranslationType.artist),
      ..._entriesFor(TagsTranslation.groupTags, TranslationType.group),
      ..._entriesFor(TagsTranslation.cosplayerTags, TranslationType.cosplayer),
    ]);
  }

  static Iterable<_TagSuggestionEntry> _entriesFor(
    Map<String, String> map,
    TranslationType type,
  ) sync* {
    for (final entry in map.entries) {
      yield _TagSuggestionEntry(entry.key, entry.value, type);
    }
  }
}

class _TagSuggestionEntry {
  const _TagSuggestionEntry(this.key, this.value, this.type);

  final String key;
  final String value;
  final TranslationType type;

  bool matches(String text) => TagSuggestions.matches(text, key, value);
}

class _SuggestionQuery {
  const _SuggestionQuery(this.version, this.text, this.limit);

  final int version;
  final String text;
  final int limit;

  @override
  bool operator ==(Object other) {
    return other is _SuggestionQuery &&
        other.version == version &&
        other.text == text &&
        other.limit == limit;
  }

  @override
  int get hashCode => Object.hash(version, text, limit);
}
