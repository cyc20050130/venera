import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/chapter_pages_repository.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

import 'test_native_paths.dart';

void main() {
  late Directory tempDir;
  late ComicSource source;
  late Res<List<String>> currentPages;
  var loadCount = 0;

  setUpAll(() {
    open.overrideFor(OperatingSystem.windows, openTestSqlite);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'venera-chapter-pages-test-',
    );
    App.dataPath = tempDir.path;
    loadCount = 0;
    currentPages = const Res(['a', 'b', 'c']);
    ChapterPagesRepository().debugReset();
    ComicSourceManager().remove('test-source');
    source = _buildSource(
      loadComicPages: (id, ep) async {
        loadCount++;
        return currentPages;
      },
    );
    ComicSourceManager().add(source);
  });

  tearDown(() async {
    ComicSourceManager().remove('test-source');
    ChapterPagesRepository().debugReset();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('fresh cache short-circuits repeated chapter page loads', () async {
    final repo = ChapterPagesRepository();

    final first = await repo.load('test-source', 'comic-1', 'ep-1');
    final second = await repo.load('test-source', 'comic-1', 'ep-1');

    expect(first.success, isTrue);
    expect(second.success, isTrue);
    expect(second.data, ['a', 'b', 'c']);
    expect(loadCount, 1);
  });

  test(
    'stale cache refresh skips callback when chapter pages are unchanged',
    () async {
      final repo = ChapterPagesRepository();
      await repo.load(
        'test-source',
        'comic-1',
        'ep-1',
        freshFor: const Duration(milliseconds: -1),
      );

      var callbackCount = 0;
      currentPages = const Res(['a', 'b', 'c']);
      final stale = await repo.load(
        'test-source',
        'comic-1',
        'ep-1',
        onBackgroundUpdate: (pages) async {
          callbackCount++;
        },
      );
      expect(stale.success, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(callbackCount, 0);
    },
  );

  test('stale cache refresh notifies when chapter pages change', () async {
    final repo = ChapterPagesRepository();
    await repo.load(
      'test-source',
      'comic-1',
      'ep-1',
      freshFor: const Duration(milliseconds: -1),
    );

    currentPages = const Res(['a', 'b', 'c', 'd']);
    List<String>? changedPages;
    final changed = await repo.load(
      'test-source',
      'comic-1',
      'ep-1',
      freshFor: const Duration(milliseconds: -1),
      onBackgroundUpdate: (pages) async {
        changedPages = pages;
      },
    );
    expect(changed.success, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(changedPages, ['a', 'b', 'c', 'd']);
  });

  test('fallback returns stale pages when network refresh fails', () async {
    final repo = ChapterPagesRepository();
    await repo.load(
      'test-source',
      'comic-1',
      'ep-1',
      freshFor: const Duration(milliseconds: -1),
    );

    currentPages = const Res.error('network down');
    final fallback = await repo.load(
      'test-source',
      'comic-1',
      'ep-1',
      refreshIfStale: false,
    );

    expect(fallback.success, isTrue);
    expect(fallback.data, ['a', 'b', 'c']);
  });

  test('force refresh ignores malformed previous payload rows', () async {
    final repo = ChapterPagesRepository();
    await repo.init();

    final db = sqlite3.open('${tempDir.path}/comic_details.db');
    addTearDown(db.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      INSERT OR REPLACE INTO chapter_pages_cache (
        source_key,
        comic_id,
        chapter_id,
        payload,
        updated_at,
        fresh_until
      ) VALUES (?, ?, ?, ?, ?, ?);
      ''',
      [
        'test-source',
        'comic-1',
        'ep-1',
        Uint8List.fromList([1, 2, 3]),
        now,
        now,
      ],
    );

    final refreshed = await repo.load(
      'test-source',
      'comic-1',
      'ep-1',
      forceRefresh: true,
    );

    expect(refreshed.success, isTrue);
    expect(refreshed.data, ['a', 'b', 'c']);
  });
}

ComicSource _buildSource({required LoadComicPagesFunc loadComicPages}) {
  return ComicSource(
    'Test Source',
    'test-source',
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    (id) async => Res(_buildDetails(id)),
    null,
    loadComicPages,
    null,
    null,
    '',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

ComicDetails _buildDetails(String id) {
  return ComicDetails.fromJson({
    'title': 'Title',
    'subTitle': 'Author',
    'cover': 'https://example.com/cover.jpg',
    'description': 'desc',
    'tags': <String, List<String>>{
      'tag': ['a'],
    },
    'chapters': null,
    'thumbnails': null,
    'recommend': null,
    'sourceKey': 'test-source',
    'comicId': id,
    'isFavorite': false,
    'subId': null,
    'isLiked': false,
    'likesCount': 1,
    'commentCount': 2,
    'uploader': 'tester',
    'uploadTime': '2026-05-22',
    'updateTime': '2026-05-22',
    'url': 'https://example.com/comic',
    'stars': 4.5,
    'maxPage': 0,
    'comments': null,
  });
}
