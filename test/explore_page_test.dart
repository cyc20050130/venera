import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/explore_page.dart';

void main() {
  test('normalizeExploreComicList keeps only comic objects', () {
    final comic = Comic.fromJson({
      'title': 'Title',
      'cover': 'cover',
      'id': 'id',
    }, 'source');

    expect(normalizeExploreComicList([comic, 'bad']), [comic]);
    expect(normalizeExploreComicList('bad'), isEmpty);
  });

  test('normalizeMultiPartExploreState tolerates stale page storage data', () {
    final part = ExplorePagePart('Part', const [], null);

    expect(normalizeMultiPartExploreState('bad'), isNull);
    expect(
      normalizeMultiPartExploreState({
        'loading': false,
        'message': 1,
        'parts': ['bad'],
      }),
      isNull,
    );

    final normalized = normalizeMultiPartExploreState({
      'loading': false,
      'message': '',
      'parts': [part, 'bad'],
    });
    expect(normalized, isNotNull);
    expect(normalized!['loading'], isFalse);
    expect(normalized['message'], isNull);
    expect(normalized['parts'], [part]);
  });
}
