import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/pages/favorites/favorites_page.dart';

import 'test_native_paths.dart';

void main() {
  setUpAll(() {
    open.overrideFor(OperatingSystem.windows, openTestSqlite);
  });

  test(
    'normalizeFavoriteFolderSelection tolerates malformed implicit data',
    () {
      expect(normalizeFavoriteFolderSelection(null), (
        folder: null,
        isNetwork: false,
      ));
      expect(normalizeFavoriteFolderSelection('bad'), (
        folder: null,
        isNetwork: false,
      ));
      expect(normalizeFavoriteFolderSelection({'name': ''}), (
        folder: null,
        isNetwork: false,
      ));
      expect(
        normalizeFavoriteFolderSelection({'name': 'local', 'isNetwork': false}),
        (folder: 'local', isNetwork: false),
      );
      expect(
        normalizeFavoriteFolderSelection({'name': 'net', 'isNetwork': 'true'}),
        (folder: 'net', isNetwork: true),
      );
      expect(
        normalizeFavoriteFolderSelection({'name': 'net', 'isNetwork': 1}),
        (folder: 'net', isNetwork: true),
      );
    },
  );

  test('normalizeLocalFavoritesReadFilter accepts only known filters', () {
    expect(normalizeLocalFavoritesReadFilter(null), 'All');
    expect(normalizeLocalFavoritesReadFilter('All'), 'All');
    expect(normalizeLocalFavoritesReadFilter('UnCompleted'), 'UnCompleted');
    expect(normalizeLocalFavoritesReadFilter('Completed'), 'Completed');
    expect(normalizeLocalFavoritesReadFilter('bad'), 'All');
    expect(normalizeLocalFavoritesReadFilter(1), 'All');
    expect(normalizeLocalFavoritesReadFilter(['Completed']), 'All');
  });

  test('FavoriteItem.fromJson tolerates string type and mixed tags', () {
    final item = FavoriteItem.fromJson({
      'target': 123,
      'name': 'Imported',
      'author': null,
      'coverPath': 'https://example.test/cover.jpg',
      'type': '0',
      'tags': ['a', 1, 'b'],
    });

    expect(item.id, '123');
    expect(item.author, '');
    expect(item.type.value, 'picacg'.hashCode);
    expect(item.tags, ['a', 'b']);
  });

  test('FavoriteItem.fromJson rejects missing required fields', () {
    expect(
      () => FavoriteItem.fromJson({'name': 'Missing id', 'type': 0}),
      throwsFormatException,
    );
    expect(
      () => FavoriteItem.fromJson({'id': 'comic', 'name': 'Missing type'}),
      throwsFormatException,
    );
  });

  test('FavoriteItem json helpers normalize malformed values', () {
    expect(FavoriteItem.normalizeJsonTags('tag'), isEmpty);
    expect(FavoriteItem.normalizeJsonTags(['tag', 1]), ['tag']);
    expect(FavoriteItem.normalizeJsonType(6, ''), 'nhentai'.hashCode);
  });

  test('FavoriteItem.fromRow tolerates scalar legacy row values', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute('''
      create table favorites (
        id text,
        name text,
        author text,
        type int,
        tags text,
        cover_path text,
        time text
      );
    ''');
    db.execute('insert into favorites values (?, ?, ?, ?, ?, ?, ?);', [
      123,
      456,
      null,
      '0',
      'a,, b ',
      'https://example.test/cover.jpg',
      'bad',
    ]);

    final item = FavoriteItem.fromRow(
      db.select('select * from favorites').first,
    );

    expect(item.id, '123');
    expect(item.name, '456');
    expect(item.author, '');
    expect(item.type.value, 'picacg'.hashCode);
    expect(item.tags, ['a', 'b']);
    expect(item.coverPath, 'https://example.test/cover.jpg');
    expect(item.time, isNot('bad'));
    expect(item.time, hasLength(19));
  });

  test('FavoriteItem row helpers fall back on invalid row type', () {
    expect(FavoriteItem.normalizeRowType('bad', ''), 0);
    expect(FavoriteItem.normalizeRowTags(null), isEmpty);
    expect(FavoriteItem.normalizeRowTime(null), hasLength(19));
  });
}
