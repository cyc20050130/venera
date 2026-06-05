import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

void main() {
  test('ComicDetails.fromJson tolerates mixed optional source payloads', () {
    final details = ComicDetails.fromJson({
      'title': 123,
      'subTitle': 456,
      'cover': 789,
      'description': null,
      'tags': {
        'artist': ['alice', 2, null],
        99: 'solo',
      },
      'chapters': {'1': 1, 'bad': null},
      'thumbnails': [1, 'two', null],
      'recommend': [
        {
          'title': 100,
          'cover': 200,
          'id': 300,
          'tags': [400, 'tag'],
          'maxPage': '7',
          'stars': '4.5',
        },
        'bad',
      ],
      'sourceKey': 42,
      'comicId': 10,
      'isFavorite': 'true',
      'likesCount': '5',
      'isLiked': 0,
      'commentCount': '6',
      'stars': '3.5',
      'maxPage': '8',
      'comments': [
        {
          'userName': 123,
          'content': 456,
          'replyCount': '2',
          'id': 9,
          'score': '3',
          'isLiked': 'yes',
          'voteStatus': '-1',
        },
        null,
      ],
    });

    expect(details.title, '123');
    expect(details.subTitle, '456');
    expect(details.cover, '789');
    expect(details.tags['artist'], ['alice', '2']);
    expect(details.tags['99'], ['solo']);
    expect(details.chapters?.allChapters, {'1': '1'});
    expect(details.thumbnails, ['1', 'two']);
    expect(details.recommend, hasLength(1));
    expect(details.recommend!.single.id, '300');
    expect(details.recommend!.single.tags, ['400', 'tag']);
    expect(details.recommend!.single.maxPage, 7);
    expect(details.isFavorite, isTrue);
    expect(details.likesCount, 5);
    expect(details.isLiked, isFalse);
    expect(details.commentCount, 6);
    expect(details.maxPage, 8);
    expect(details.stars, 3.5);
    expect(details.comments, hasLength(1));
    expect(details.comments!.single.userName, '123');
    expect(details.comments!.single.replyCount, 2);
    expect(details.comments!.single.isLiked, isTrue);
    expect(details.comments!.single.voteStatus, -1);
  });

  test(
    'normalizeComicDetailsPayload accepts source maps with non-string keys',
    () {
      final details = normalizeComicDetailsPayload(
        {'title': 123, 'cover': 456, 99: 'ignored-key-is-stringified'},
        sourceKey: 'source',
        comicId: 'comic-id',
      );

      expect(details, isNotNull);
      expect(details!.title, '123');
      expect(details.cover, '456');
      expect(details.sourceKey, 'source');
      expect(details.comicId, 'comic-id');
      expect(
        normalizeComicDetailsPayload('bad', sourceKey: 's', comicId: 'c'),
        isNull,
      );
    },
  );

  test('normalizeFavoriteFoldersPayload tolerates mixed source payloads', () {
    final folders = normalizeFavoriteFoldersPayload({
      'folders': {'a': 'A', 2: 3, 'bad': null},
      'favorited': ['a', 2, null, ''],
    });

    expect(folders, isNotNull);
    expect(folders!.folders, {'a': 'A', '2': '3'});
    expect(folders.favorited, ['a', '2', '']);
    final emptyFolders = normalizeFavoriteFoldersPayload({
      'folders': 'bad',
      'favorited': 'bad',
    });
    expect(emptyFolders, isNotNull);
    expect(emptyFolders!.folders, isEmpty);
    expect(emptyFolders.favorited, isEmpty);
    expect(normalizeFavoriteFoldersPayload('bad'), isNull);
  });

  test('normalizeFavoriteDataFlags tolerates non-bool source values', () {
    expect(
      normalizeFavoriteDataFlags(
        multiFolder: 'true',
        isOldToNewSort: 1,
        singleFolderForSingleComic: 'yes',
      ),
      (
        multiFolder: true,
        isOldToNewSort: true,
        singleFolderForSingleComic: true,
      ),
    );

    expect(
      normalizeFavoriteDataFlags(
        multiFolder: 'bad',
        isOldToNewSort: 'bad',
        singleFolderForSingleComic: ['bad'],
      ),
      (
        multiFolder: false,
        isOldToNewSort: null,
        singleFolderForSingleComic: false,
      ),
    );
  });

  test('comicSourceBool normalizes callback bool-like results', () {
    expect(comicSourceBool(true), isTrue);
    expect(comicSourceBool(false), isFalse);
    expect(comicSourceBool(1), isTrue);
    expect(comicSourceBool(0), isFalse);
    expect(comicSourceBool('yes'), isTrue);
    expect(comicSourceBool('NO'), isFalse);
    expect(comicSourceBool('bad'), isNull);
    expect(comicSourceBool(['bad']), isNull);
  });

  test('comicSourceStringListOrNull tolerates malformed optional lists', () {
    expect(comicSourceStringListOrNull(null), isNull);
    expect(comicSourceStringListOrNull('bad'), isEmpty);
    expect(comicSourceStringListOrNull([1, 'two', null]), ['1', 'two']);
  });

  test('Comment.parseTime tolerates out-of-range timestamps', () {
    expect(Comment.parseTime(null), isNull);
    expect(Comment.parseTime(1710000000), Comment.parseTime(1710000000000));
    expect(Comment.parseTime(1710000000), hasLength(19));
    expect(Comment.parseTime(999999999999999999), '999999999999999999');
    expect(Comment.parseTime('plain time'), 'plain time');
  });

  test(
    'ComicChapters.fromJson normalizes grouped non-string keys and values',
    () {
      final chapters = ComicChapters.fromJson({
        1: {2: 'Two', '3': 3, 'bad': null},
      });

      expect(chapters.isGrouped, isTrue);
      expect(chapters.getGroup('1'), {'2': 'Two', '3': '3'});
      expect(ComicChapters.fromJsonOrNull('bad'), isNull);
    },
  );

  test(
    'ComicChapters grouped access tolerates empty and out-of-range groups',
    () {
      final empty = ComicChapters.grouped({});
      expect(empty.length, 0);
      expect(empty.getGroupByIndex(0), isEmpty);
      expect(empty.getGroupByIndex(-1), isEmpty);

      final chapters = ComicChapters.grouped({
        'Empty': {},
        'Main': {'1': 'One'},
      });
      expect(chapters.length, 1);
      expect(chapters.getGroupByIndex(-1), isEmpty);
      expect(chapters.getGroupByIndex(99), isEmpty);
      expect(chapters.getGroupByIndex(1), {'1': 'One'});
    },
  );

  test('PageJumpTarget parse ignores malformed attributes safely', () {
    final target = PageJumpTarget.parse('source', {
      'page': 123,
      'attributes': ['bad'],
    });

    expect(target.page, '123');
    expect(target.attributes, isNull);

    final legacy = PageJumpTarget.parse('source', {
      'action': 'search',
      'keyword': 42,
    });
    expect(legacy.page, 'search');
    expect(legacy.attributes?['text'], '42');
  });

  test('ArchiveInfo.fromJson normalizes scalar fields', () {
    final archive = ArchiveInfo.fromJson({
      'title': 1,
      'description': 2,
      'id': 3,
    });

    expect(archive.title, '1');
    expect(archive.description, '2');
    expect(archive.id, '3');
  });

  test('normalizeSourceSettings skips malformed setting entries', () {
    final settings = normalizeSourceSettings({
      'select': {
        'type': 'select',
        1: 'ignored',
        'title': 2,
        'options': [
          {'value': 'a'},
        ],
      },
      'bad': 'not-a-map',
      1: {'type': 'input'},
    });

    expect(settings.keys, ['select']);
    expect(settings['select']!['type'], 'select');
    expect(settings['select']!.containsKey(1), isFalse);
    expect(settings['select']!['title'], 2);
  });

  test('normalizeStoredAccountCredentials validates persisted login data', () {
    expect(normalizeStoredAccountCredentials(['user', 'pass']), (
      username: 'user',
      password: 'pass',
    ));
    expect(normalizeStoredAccountCredentials(['user', 'pass', 'extra']), (
      username: 'user',
      password: 'pass',
    ));

    expect(normalizeStoredAccountCredentials(null), isNull);
    expect(normalizeStoredAccountCredentials('ok'), isNull);
    expect(normalizeStoredAccountCredentials(['user']), isNull);
    expect(normalizeStoredAccountCredentials([1, 'pass']), isNull);
    expect(normalizeStoredAccountCredentials(['user', 2]), isNull);
    expect(normalizeStoredAccountCredentials({'user': 'pass'}), isNull);
  });

  test('explore parser helpers filter malformed source payload entries', () {
    final comicJson = {'title': 'Title', 'cover': 'cover', 'id': 'id'};

    final comics = normalizeSourceComicList([comicJson, 'bad'], 'source');
    expect(comics, hasLength(1));
    expect(comics.single.title, 'Title');

    final parts = normalizeExplorePageParts({
      'Part': [comicJson, 'bad'],
      'Empty': ['bad'],
    }, 'source');
    expect(parts, hasLength(1));
    expect(parts.single.title, 'Part');
    expect(parts.single.comics, hasLength(1));

    final mixed = normalizeMixedExploreData([
      [comicJson, 'bad'],
      {
        'title': 'More',
        'comics': [comicJson],
        'viewMore': {
          'page': 'search',
          'attributes': {'text': 'tag'},
        },
      },
      'bad',
    ], 'source');
    expect(mixed, hasLength(2));
    expect(mixed.first, isA<List<Comic>>());
    expect(mixed.last, isA<ExplorePagePart>());
  });

  test('normalizeExplorePageDefinition skips malformed page config', () {
    expect(normalizeExplorePageDefinition(123, 'multiPageComicList'), (
      title: '123',
      type: ExplorePageType.multiPageComicList,
    ));
    expect(normalizeExplorePageDefinition('Part', 'multiPartPage'), (
      title: 'Part',
      type: ExplorePageType.singlePageWithMultiPart,
    ));
    expect(normalizeExplorePageDefinition('Part', 'singlePageWithMultiPart'), (
      title: 'Part',
      type: ExplorePageType.singlePageWithMultiPart,
    ));
    expect(normalizeExplorePageDefinition('Mixed', 'mixed'), (
      title: 'Mixed',
      type: ExplorePageType.mixed,
    ));

    expect(normalizeExplorePageDefinition('', 'mixed'), isNull);
    expect(normalizeExplorePageDefinition('Part', null), isNull);
    expect(normalizeExplorePageDefinition('Part', 'unknown'), isNull);
  });

  test('normalizeSourceComicListResult filters malformed list payloads', () {
    final comicJson = {'title': 'Title', 'cover': 'cover', 'id': 'id'};

    final result = normalizeSourceComicListResult(
      {
        'comics': [comicJson, 'bad'],
        'next': 'cursor',
      },
      'source',
      subDataKey: 'next',
    );

    expect(result.error, isFalse);
    expect(result.data, hasLength(1));
    expect(result.data.single.id, 'id');
    expect(result.subData, 'cursor');

    final invalid = normalizeSourceComicListResult('bad', 'source');
    expect(invalid.error, isTrue);
  });
}
