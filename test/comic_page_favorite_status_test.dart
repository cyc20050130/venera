import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';

void main() {
  test(
    'favorite status refresh returns immediately and updates later',
    () async {
      final completer = Completer<Res<Map<String, String>>>();
      bool? updatedFavorite;

      refreshComicFavoriteStatusInBackground(
        favoriteData: FavoriteData(
          key: 'test',
          title: 'test',
          multiFolder: true,
          loadComic: null,
          loadNext: null,
          loadFolders: ([String? comicId]) => completer.future,
        ),
        isLogged: true,
        comicId: 'comic-id',
        requestId: 1,
        isMounted: () => true,
        isCurrentRequest: (requestId) => requestId == 1,
        onFavoriteLoaded: (isFavorite) {
          updatedFavorite = isFavorite;
        },
      );

      expect(updatedFavorite, isNull);

      completer.complete(
        const Res({'folder-1': 'Folder 1'}, subData: ['folder-1']),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(updatedFavorite, isTrue);
    },
  );

  test('favorite folder status tolerates mixed source subData', () async {
    expect(normalizeFavoriteFolderIds(['folder-1', 2, null, '']), [
      'folder-1',
      '2',
    ]);

    final completer = Completer<Res<Map<String, String>>>();
    bool? updatedFavorite;

    refreshComicFavoriteStatusInBackground(
      favoriteData: FavoriteData(
        key: 'test',
        title: 'test',
        multiFolder: true,
        loadComic: null,
        loadNext: null,
        loadFolders: ([String? comicId]) => completer.future,
      ),
      isLogged: true,
      comicId: 'comic-id',
      requestId: 1,
      isMounted: () => true,
      isCurrentRequest: (requestId) => requestId == 1,
      onFavoriteLoaded: (isFavorite) {
        updatedFavorite = isFavorite;
      },
    );

    completer.complete(const Res({'folder-1': 'Folder 1'}, subData: [2]));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(updatedFavorite, isTrue);
  });

  test('chapter reverse order setting tolerates synced non-bool values', () {
    expect(shouldReverseChapterOrder(true), isTrue);
    expect(shouldReverseChapterOrder(false), isFalse);
    expect(shouldReverseChapterOrder('true'), isTrue);
    expect(shouldReverseChapterOrder('false'), isFalse);
    expect(shouldReverseChapterOrder(1), isTrue);
    expect(shouldReverseChapterOrder(0), isFalse);
    expect(shouldReverseChapterOrder('bad'), isFalse);
    expect(shouldReverseChapterOrder(['true']), isFalse);
    expect(shouldReverseChapterOrder(null), isFalse);
  });

  test('grouped chapter tab count uses groups rather than chapter count', () {
    expect(
      comicDetailGroupedChapterTabCount(
        ComicChapters.grouped({
          'A': {'a1': 'A1', 'a2': 'A2'},
          'B': {'b1': 'B1', 'b2': 'B2', 'b3': 'B3'},
        }),
      ),
      2,
    );
    expect(comicDetailGroupedChapterTabCount(ComicChapters.grouped({})), 0);
  });

  test('local favorites first setting tolerates synced non-bool values', () {
    expect(shouldShowLocalFavoritesFirst(true), isTrue);
    expect(shouldShowLocalFavoritesFirst(false), isFalse);
    expect(shouldShowLocalFavoritesFirst('true'), isTrue);
    expect(shouldShowLocalFavoritesFirst('false'), isFalse);
    expect(shouldShowLocalFavoritesFirst(1), isTrue);
    expect(shouldShowLocalFavoritesFirst(0), isFalse);
    expect(shouldShowLocalFavoritesFirst('bad'), isTrue);
    expect(shouldShowLocalFavoritesFirst(['true']), isTrue);
    expect(shouldShowLocalFavoritesFirst(null), isTrue);
  });

  test(
    'auto close favorite panel setting tolerates synced non-bool values',
    () {
      expect(shouldAutoCloseFavoritePanel(true), isTrue);
      expect(shouldAutoCloseFavoritePanel(false), isFalse);
      expect(shouldAutoCloseFavoritePanel('true'), isTrue);
      expect(shouldAutoCloseFavoritePanel('false'), isFalse);
      expect(shouldAutoCloseFavoritePanel(1), isTrue);
      expect(shouldAutoCloseFavoritePanel(0), isFalse);
      expect(shouldAutoCloseFavoritePanel('bad'), isFalse);
      expect(shouldAutoCloseFavoritePanel(['true']), isFalse);
      expect(shouldAutoCloseFavoritePanel(null), isFalse);
    },
  );

  test('comic detail time formatter tolerates malformed source values', () {
    final expected = DateTime.fromMillisecondsSinceEpoch(
      1710000000000,
    ).toString().substring(0, 19);
    expect(formatComicDetailTime('1710000000000'), expected);
    expect(formatComicDetailTime('1710000000'), expected);
    expect(
      formatComicDetailTime('2026-06-05T12:34:56Z'),
      startsWith('2026-06-05'),
    );
    expect(formatComicDetailTime('badTtime'), 'badTtime');
    expect(formatComicDetailTime('plain date'), 'plain date');
  });

  test('network favorite panel applies only mounted current results', () {
    expect(
      shouldApplyComicPageAsyncResult(
        mounted: true,
        requestId: 2,
        activeRequestId: 2,
      ),
      isTrue,
    );

    expect(
      shouldApplyComicPageAsyncResult(
        mounted: false,
        requestId: 2,
        activeRequestId: 2,
      ),
      isFalse,
    );

    expect(
      shouldApplyComicPageAsyncResult(
        mounted: true,
        requestId: 1,
        activeRequestId: 2,
      ),
      isFalse,
    );

    expect(
      shouldApplyNetworkFavoritePanelResult(
        mounted: true,
        requestId: 2,
        activeRequestId: 2,
      ),
      isTrue,
    );

    expect(
      shouldApplyNetworkFavoritePanelResult(
        mounted: false,
        requestId: 2,
        activeRequestId: 2,
      ),
      isFalse,
    );

    expect(
      shouldApplyNetworkFavoritePanelResult(
        mounted: true,
        requestId: 1,
        activeRequestId: 2,
      ),
      isFalse,
    );
  });

  test('comic page source dependent actions require a live source', () {
    expect(shouldEnableComicPageSourceAction(null), isFalse);
    expect(shouldEnableComicPageSourceAction(_testComicSource()), isTrue);
  });

  test('stale requests do not update favorite status', () async {
    final completer = Completer<Res<Map<String, String>>>();
    bool didUpdate = false;

    refreshComicFavoriteStatusInBackground(
      favoriteData: FavoriteData(
        key: 'test',
        title: 'test',
        multiFolder: true,
        loadComic: null,
        loadNext: null,
        loadFolders: ([String? comicId]) => completer.future,
      ),
      isLogged: true,
      comicId: 'comic-id',
      requestId: 1,
      isMounted: () => true,
      isCurrentRequest: (requestId) => false,
      onFavoriteLoaded: (isFavorite) {
        didUpdate = true;
      },
    );

    completer.complete(
      const Res({'folder-1': 'Folder 1'}, subData: ['folder-1']),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(didUpdate, isFalse);
  });

  test(
    'favorite status refresh can be invalidated after user action',
    () async {
      final completer = Completer<Res<Map<String, String>>>();
      bool didUpdate = false;
      var activeRequestId = 1;

      refreshComicFavoriteStatusInBackground(
        favoriteData: FavoriteData(
          key: 'test',
          title: 'test',
          multiFolder: true,
          loadComic: null,
          loadNext: null,
          loadFolders: ([String? comicId]) => completer.future,
        ),
        isLogged: true,
        comicId: 'comic-id',
        requestId: activeRequestId,
        isMounted: () => true,
        isCurrentRequest: (requestId) => requestId == activeRequestId,
        onFavoriteLoaded: (isFavorite) {
          didUpdate = true;
        },
      );

      activeRequestId++;
      completer.complete(
        const Res({'folder-1': 'Folder 1'}, subData: ['folder-1']),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(didUpdate, isFalse);
    },
  );
}

ComicSource _testComicSource() {
  return ComicSource(
    'Source',
    'source',
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    'source.js',
    'https://example.test/source.js',
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
