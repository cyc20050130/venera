import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/utils/tags_translation.dart';

import 'test_native_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Database db;

  setUpAll(() {
    open.overrideFor(OperatingSystem.windows, openTestSqlite);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-favorites-test-');
    App.dataPath = tempDir.path;
    db = sqlite3.open('${tempDir.path}/local_favorite.db');
    _createLegacyFavoriteFolder(db);
  });

  tearDown(() async {
    db.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('startup schema migration does not backfill translated tags', () {
    final addedColumn = LocalFavoritesManager.ensureTranslatedTagsColumns(db, [
      'default',
    ]);

    expect(addedColumn, isTrue);
    final columns = db.select('pragma table_info("default");');
    expect(
      columns.any((column) => column['name'] == 'translated_tags'),
      isTrue,
    );
    final row = db.select('select translated_tags from "default";').first;
    expect(row['translated_tags'], isNull);
  });

  test('translated tag backfill runs after tag data is ready', () async {
    appdata.settings['language'] = 'zh-CN';
    await TagsTranslation.readData();
    LocalFavoritesManager.ensureTranslatedTagsColumns(db, ['default']);

    final updated = LocalFavoritesManager.backfillTranslatedTags(db, [
      'default',
    ]);

    expect(updated, 1);
    final row = db.select('select translated_tags from "default";').first;
    expect(row['translated_tags'], isNotNull);
    expect(row['translated_tags'], isNotEmpty);
  });

  test('legacy translated tag search backfills before first search', () async {
    appdata.settings['language'] = 'zh-CN';
    await TagsTranslation.readData();

    LocalFavoritesManager.ensureTranslatedTagsColumns(db, ['default']);
    final manager = LocalFavoritesManager();
    manager.debugUseDatabaseForTest(db, needsTagBackfill: true);

    final results = manager.search('年龄');

    expect(results.map((comic) => comic.id), contains('comic-1'));
    final row = db.select('select translated_tags from "default";').first;
    expect(row['translated_tags'], isNotNull);
  });
}

void _createLegacyFavoriteFolder(Database db) {
  db.execute('''
    create table folder_order (
      folder_name text primary key,
      order_value int
    );
  ''');
  db.execute(
    'insert into folder_order (folder_name, order_value) values (?, ?);',
    ['default', 0],
  );
  db.execute('''
    create table "default" (
      id text,
      name text,
      author text,
      type int,
      tags text,
      cover_path text,
      time text,
      display_order int,
      primary key (id, type)
    );
  ''');
  db.execute(
    '''
    insert into "default"
      (id, name, author, type, tags, cover_path, time, display_order)
    values (?, ?, ?, ?, ?, ?, ?, ?);
  ''',
    [
      'comic-1',
      'Comic',
      'Author',
      1,
      'age progression',
      'cover.jpg',
      '2026-06-15 00:00:00',
      0,
    ],
  );
}
