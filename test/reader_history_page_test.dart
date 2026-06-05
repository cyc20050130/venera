import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  test('computeReaderHistoryPage skips empty chapters', () {
    expect(
      computeReaderHistoryPage(
        page: 1,
        maxPage: 0,
        imageCount: 0,
        imagesPerPage: 1,
        showSingleImageOnFirstPage: false,
      ),
      isNull,
    );
  });

  test('computeReaderHistoryPage records the last image on the last page', () {
    expect(
      computeReaderHistoryPage(
        page: 3,
        maxPage: 3,
        imageCount: 5,
        imagesPerPage: 2,
        showSingleImageOnFirstPage: false,
      ),
      5,
    );
  });

  test('computeReaderHistoryPage respects single first-page layout', () {
    expect(
      computeReaderHistoryPage(
        page: 2,
        maxPage: 3,
        imageCount: 5,
        imagesPerPage: 2,
        showSingleImageOnFirstPage: true,
      ),
      2,
    );
  });

  test('normalizeReaderPageForLoadedImages clamps stale history pages', () {
    expect(normalizeReaderPageForLoadedImages(page: 1, maxPage: 5), 1);
    expect(normalizeReaderPageForLoadedImages(page: 5, maxPage: 5), 5);
    expect(normalizeReaderPageForLoadedImages(page: 99, maxPage: 5), 5);
    expect(normalizeReaderPageForLoadedImages(page: 0, maxPage: 5), 1);
    expect(normalizeReaderPageForLoadedImages(page: -7, maxPage: 5), 1);
    expect(normalizeReaderPageForLoadedImages(page: 3, maxPage: 0), 1);
  });
}
