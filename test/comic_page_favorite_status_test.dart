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

  test('favorite status refresh can be invalidated after user action', () async {
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
  });
}
