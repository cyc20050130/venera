import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_details_repository.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';

import 'test_native_paths.dart';

void main() {
  late Directory tempDir;
  late ComicSource source;
  late ComicDetails currentDetails;
  var loadCount = 0;

  setUpAll(() {
    open.overrideFor(OperatingSystem.windows, openTestSqlite);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'venera-comic-details-test-',
    );
    App.dataPath = tempDir.path;
    loadCount = 0;
    currentDetails = _buildDetails('Title A');
    ComicDetailsRepository().debugReset();
    ComicSourceManager().remove('test-source');
    source = _buildSource(
      loadComicInfo: (id) async {
        loadCount++;
        return Res(currentDetails);
      },
    );
    ComicSourceManager().add(source);
  });

  tearDown(() async {
    ComicSourceManager().remove('test-source');
    ComicDetailsRepository().debugReset();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'stale cache refresh skips callback when payload is unchanged',
    () async {
      final repo = ComicDetailsRepository();
      await repo.save(
        currentDetails,
        freshFor: const Duration(milliseconds: -1),
      );

      var callbackCount = 0;
      final res = await repo.load(
        'test-source',
        'comic-1',
        onBackgroundUpdate: (details) async {
          callbackCount++;
        },
      );

      expect(res.success, isTrue);
      expect(res.data.title, 'Title A');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(callbackCount, 0);
      expect(loadCount, 1);
    },
  );

  test('stale cache refresh notifies when payload changes', () async {
    final repo = ComicDetailsRepository();
    await repo.save(currentDetails, freshFor: const Duration(milliseconds: -1));
    currentDetails = _buildDetails('Title B');

    ComicDetails? callbackDetails;
    final res = await repo.load(
      'test-source',
      'comic-1',
      onBackgroundUpdate: (details) async {
        callbackDetails = details;
      },
    );

    expect(res.success, isTrue);
    expect(res.data.title, 'Title A');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(callbackDetails?.title, 'Title B');
    expect(loadCount, 1);
  });
}

ComicSource _buildSource({required LoadComicFunc loadComicInfo}) {
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
    loadComicInfo,
    null,
    null,
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

ComicDetails _buildDetails(String title) {
  return ComicDetails.fromJson({
    'title': title,
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
    'comicId': 'comic-1',
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
