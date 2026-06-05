import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

void main() {
  test('comic tile status settings tolerate malformed synced values', () {
    expect(shouldShowFavoriteStatusOnTile(true), isTrue);
    expect(shouldShowFavoriteStatusOnTile(false), isFalse);
    expect(shouldShowFavoriteStatusOnTile('true'), isTrue);
    expect(shouldShowFavoriteStatusOnTile('false'), isFalse);
    expect(shouldShowFavoriteStatusOnTile(1), isTrue);
    expect(shouldShowFavoriteStatusOnTile(0), isFalse);
    expect(shouldShowFavoriteStatusOnTile('bad'), isFalse);
    expect(shouldShowFavoriteStatusOnTile(['true']), isFalse);
    expect(shouldShowFavoriteStatusOnTile(null), isFalse);

    expect(shouldShowHistoryStatusOnTile(true), isTrue);
    expect(shouldShowHistoryStatusOnTile(false), isFalse);
    expect(shouldShowHistoryStatusOnTile('true'), isTrue);
    expect(shouldShowHistoryStatusOnTile('false'), isFalse);
    expect(shouldShowHistoryStatusOnTile(1), isTrue);
    expect(shouldShowHistoryStatusOnTile(0), isFalse);
    expect(shouldShowHistoryStatusOnTile('bad'), isFalse);
    expect(shouldShowHistoryStatusOnTile(['true']), isFalse);
    expect(shouldShowHistoryStatusOnTile(null), isFalse);
  });

  test('formatComicTileBadge skips empty source language values', () {
    expect(formatComicTileBadge(null), isNull);
    expect(formatComicTileBadge(''), isNull);
    expect(formatComicTileBadge('   '), isNull);
    expect(formatComicTileBadge('j'), 'J');
    expect(formatComicTileBadge('JP'), 'Jp');
    expect(formatComicTileBadge(' english '), 'English');
  });

  test('normalizeComicListStorageState tolerates stale page storage data', () {
    final comic = Comic.fromJson({
      'title': 'Title',
      'cover': 'cover',
      'id': 'id',
    }, 'source');

    expect(normalizeComicListStorageState('bad'), isNull);

    final normalized = normalizeComicListStorageState({
      'maxPage': '2',
      'page': '5',
      'error': 1,
      'nextUrl': 2,
      'data': {
        '1': [comic, 'bad'],
        0: [comic],
        'bad': [comic],
        2: 'bad',
      },
      'loading': {'1': true, 2: 'bad', 0: true},
    });

    expect(normalized, isNotNull);
    expect(normalized!['maxPage'], 2);
    expect(normalized['page'], 2);
    expect(normalized['error'], isNull);
    expect(normalized['nextUrl'], isNull);
    expect(normalized['data'], {
      1: [comic],
    });
    expect(normalized['loading'], {1: true});
  });
}
