import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/image_favorites_page/image_favorites_page.dart';

void main() {
  tearDown(() {
    ImageFavoritesPhotoView.debugPageControllerFactory = null;
  });

  test(
    'image favorite menu action result only applies to active page request',
    () {
      expect(
        shouldApplyImageFavoriteMenuActionResult(
          mounted: true,
          requestId: 2,
          activeRequestId: 2,
          page: 3,
          currentPage: 3,
        ),
        isTrue,
      );
      expect(
        shouldApplyImageFavoriteMenuActionResult(
          mounted: false,
          requestId: 2,
          activeRequestId: 2,
          page: 3,
          currentPage: 3,
        ),
        isFalse,
      );
      expect(
        shouldApplyImageFavoriteMenuActionResult(
          mounted: true,
          requestId: 1,
          activeRequestId: 2,
          page: 3,
          currentPage: 3,
        ),
        isFalse,
      );
      expect(
        shouldApplyImageFavoriteMenuActionResult(
          mounted: true,
          requestId: 2,
          activeRequestId: 2,
          page: 3,
          currentPage: 4,
        ),
        isFalse,
      );
    },
  );

  test('image favorite menu page must stay inside image list bounds', () {
    expect(isValidImageFavoriteMenuPage(page: 0, imageCount: 1), isTrue);
    expect(isValidImageFavoriteMenuPage(page: -1, imageCount: 1), isFalse);
    expect(isValidImageFavoriteMenuPage(page: 1, imageCount: 1), isFalse);
    expect(isValidImageFavoriteMenuPage(page: 0, imageCount: 0), isFalse);
  });

  testWidgets('ImageFavoritesPhotoView disposes its owned PageController', (
    tester,
  ) async {
    final controllers = <_TrackingPageController>[];
    ImageFavoritesPhotoView.debugPageControllerFactory = (initialPage) {
      final controller = _TrackingPageController(initialPage: initialPage);
      controllers.add(controller);
      return controller;
    };

    final favorite = ImageFavorite(
      1,
      'image-key',
      null,
      'ep-1',
      'comic-id',
      1,
      'test-source',
      'Episode 1',
    );
    final comic = ImageFavoritesComic(
      'comic-id',
      const [],
      'Comic Title',
      'test-source',
      const [],
      const [],
      DateTime(2026, 6, 5),
      'Author',
      const {},
      '',
      1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ImageFavoritesPhotoView(comic: comic, imageFavorite: favorite),
      ),
    );
    expect(controllers, hasLength(1));
    expect(controllers.single.disposed, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(controllers.single.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });
}

class _TrackingPageController extends PageController {
  _TrackingPageController({required super.initialPage});

  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
