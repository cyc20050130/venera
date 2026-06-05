import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/favorites/favorites_page.dart';

void main() {
  test('normalizeFavoriteUpdatePageNum tolerates synced malformed values', () {
    expect(normalizeFavoriteUpdatePageNum(null), 9999999);
    expect(normalizeFavoriteUpdatePageNum('bad'), 9999999);
    expect(normalizeFavoriteUpdatePageNum(-1), 9999999);
    expect(normalizeFavoriteUpdatePageNum('20'), 20);
    expect(normalizeFavoriteUpdatePageNum(5), 5);
  });

  test('firstOldToNewFavoritePage clamps oversized update count', () {
    expect(firstOldToNewFavoritePage(maxPage: 10, requestedPages: 9999999), 1);
    expect(firstOldToNewFavoritePage(maxPage: 10, requestedPages: 3), 8);
    expect(firstOldToNewFavoritePage(maxPage: 0, requestedPages: 3), 1);
    expect(firstOldToNewFavoritePage(maxPage: 10, requestedPages: 0), 1);
  });

  test('normalizeFavoriteImportPage tolerates source maxPage drift', () {
    expect(normalizeFavoriteImportPage(10), 10);
    expect(normalizeFavoriteImportPage(10.9), 10);
    expect(normalizeFavoriteImportPage('20'), 20);
    expect(normalizeFavoriteImportPage('bad'), 1);
    expect(normalizeFavoriteImportPage(0, fallback: 5), 5);
    expect(normalizeFavoriteImportPage(-1, fallback: -1), 1);
    expect(normalizeFavoriteImportPage(['10']), 1);
  });

  test('isFavoriteImportLastPage compares normalized source maxPage', () {
    expect(isFavoriteImportLastPage(3, 3), isTrue);
    expect(isFavoriteImportLastPage(3.9, 3), isTrue);
    expect(isFavoriteImportLastPage('3', 3), isTrue);
    expect(isFavoriteImportLastPage('bad', 3), isFalse);
    expect(isFavoriteImportLastPage(null, 3), isFalse);
  });

  test('normalizeQuickFavoriteFolder tolerates synced malformed values', () {
    expect(normalizeQuickFavoriteFolder('folder'), 'folder');
    expect(normalizeQuickFavoriteFolder(''), isNull);
    expect(normalizeQuickFavoriteFolder(1), isNull);
    expect(normalizeQuickFavoriteFolder(['folder']), isNull);
    expect(normalizeQuickFavoriteFolder(null), isNull);
  });

  test('network favorite action results require mounted current request', () {
    expect(
      shouldApplyNetworkFavoriteActionResult(
        mounted: true,
        requestId: 2,
        activeRequestId: 2,
      ),
      isTrue,
    );
    expect(
      shouldApplyNetworkFavoriteActionResult(
        mounted: false,
        requestId: 2,
        activeRequestId: 2,
      ),
      isFalse,
    );
    expect(
      shouldApplyNetworkFavoriteActionResult(
        mounted: true,
        requestId: 1,
        activeRequestId: 2,
      ),
      isFalse,
    );
  });
}
