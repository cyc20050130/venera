import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/data.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'test_native_paths.dart';

void main() {
  late Directory tempDir;
  late Directory tempCacheDir;
  late Directory zipDllDir;
  String? originalCurrentDir;

  setUpAll(() async {
    final source = File(zipDllSourcePath);
    if (!source.existsSync()) {
      throw StateError(
        'Missing test zip dll at $zipDllSourcePath. Build it before running history tests.',
      );
    }
    originalCurrentDir = Directory.current.path;
    // A loaded DLL stays locked until the test process exits on Windows.
    // Use the stable build output directly instead of leaking a temp folder.
    zipDllDir = source.parent;
    Directory.current = zipDllDir.path;
  });

  tearDownAll(() {
    if (originalCurrentDir != null) {
      Directory.current = originalCurrentDir!;
    }
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-history-test-');
    tempCacheDir = await Directory.systemTemp.createTemp(
      'venera-history-cache-',
    );
    App.dataPath = tempDir.path;
    App.cachePath = tempCacheDir.path;
    final history = HistoryManager();
    if (history.isInitialized) {
      history.close();
    }
    await history.init();
  });

  tearDown(() async {
    final history = HistoryManager();
    history.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    if (await tempCacheDir.exists()) {
      await tempCacheDir.delete(recursive: true);
    }
  });

  test(
    'keeps separate history rows for same id with different source keys',
    () {
      final manager = HistoryManager();
      manager.addHistory(
        History.fromMap({
          'type': 'picacg'.hashCode,
          'sourceKey': 'source-a',
          'id': 'comic-1',
          'title': 'A',
          'subtitle': '',
          'cover': '',
          'time': DateTime(2024).millisecondsSinceEpoch,
          'ep': 3,
          'page': 7,
          'max_page': 10,
          'readEpisode': ['3'],
        }),
      );
      manager.addHistory(
        History.fromMap({
          'type': 'ehentai'.hashCode,
          'sourceKey': 'source-b',
          'id': 'comic-1',
          'title': 'B',
          'subtitle': '',
          'cover': '',
          'time': DateTime(2025).millisecondsSinceEpoch,
          'ep': 5,
          'page': 9,
          'max_page': 12,
          'readEpisode': ['5'],
        }),
      );

      expect(manager.getAll(), hasLength(2));
      expect(manager.findBySourceKey('comic-1', 'source-a')?.title, 'A');
      expect(manager.findBySourceKey('comic-1', 'source-b')?.title, 'B');
    },
  );

  test('history time index covers recent-history ordering', () {
    final db = sqlite3.open('${tempDir.path}/history.db');
    addTearDown(db.close);

    final indexes = db
        .select("PRAGMA index_list('history');")
        .map((row) => row['name'])
        .whereType<String>()
        .toSet();
    expect(indexes, contains('history_time_index'));

    final plan = db.select(
      'EXPLAIN QUERY PLAN SELECT * FROM history ORDER BY time DESC LIMIT 20;',
    );
    expect(
      plan.map((row) => row['detail'].toString()).join(' '),
      contains('history_time_index'),
    );
  });

  test('silent history update persists without notifying listeners', () {
    final manager = HistoryManager();
    var notifications = 0;
    void listener() {
      notifications++;
    }

    manager.addListener(listener);
    addTearDown(() => manager.removeListener(listener));

    manager.addHistory(
      History.fromMap({
        'type': 'picacg'.hashCode,
        'sourceKey': 'source-silent',
        'id': 'comic-silent',
        'title': 'Silent',
        'subtitle': '',
        'cover': '',
        'time': DateTime(2026).millisecondsSinceEpoch,
        'ep': 1,
        'page': 2,
        'max_page': 9,
        'readEpisode': ['1'],
      }),
      notify: false,
    );

    expect(notifications, 0);
    expect(manager.findBySourceKey('comic-silent', 'source-silent')?.page, 2);
  });

  test(
    'existing history metadata sync updates cover without changing progress',
    () {
      final manager = HistoryManager();
      final originalTime = DateTime(2026, 6, 4);
      var notifications = 0;
      void listener() {
        notifications++;
      }

      manager.addListener(listener);
      addTearDown(() => manager.removeListener(listener));
      manager.addHistory(
        History.fromMap({
          'type': 'picacg'.hashCode,
          'sourceKey': 'source-cover-sync',
          'id': 'comic-cover-sync',
          'title': 'Old Title',
          'subtitle': 'Old Author',
          'cover': 'old-cover',
          'time': originalTime.millisecondsSinceEpoch,
          'ep': 6,
          'page': 18,
          'group': 2,
          'max_page': 40,
          'readEpisode': ['2-6'],
        }),
        notify: false,
      );

      final changed = manager.updateExistingHistoryMetadata(
        const _TestHistoryMetadata(
          sourceKey: 'source-cover-sync',
          id: 'comic-cover-sync',
          title: 'New Title',
          subTitle: 'New Author',
          cover: 'https://example.test/new-cover.jpg',
          maxPage: 99,
        ),
      );

      expect(changed, isTrue);
      expect(notifications, 1);

      final updated = manager.findBySourceKey(
        'comic-cover-sync',
        'source-cover-sync',
      );
      expect(updated, isNotNull);
      expect(updated!.title, 'New Title');
      expect(updated.subtitle, 'New Author');
      expect(updated.cover, 'https://example.test/new-cover.jpg');
      expect(updated.maxPage, 99);
      expect(updated.time, originalTime);
      expect(updated.ep, 6);
      expect(updated.page, 18);
      expect(updated.group, 2);
      expect(updated.readEpisode, {'2-6'});
    },
  );

  test('history metadata sync does not create history rows', () {
    final manager = HistoryManager();
    final changed = manager.updateExistingHistoryMetadata(
      const _TestHistoryMetadata(
        sourceKey: 'source-cover-sync',
        id: 'missing-history',
        title: 'New Title',
        subTitle: 'New Author',
        cover: 'https://example.test/new-cover.jpg',
        maxPage: 99,
      ),
    );

    expect(changed, isFalse);
    expect(
      manager.findBySourceKey('missing-history', 'source-cover-sync'),
      isNull,
    );
  });

  test('unchanged history metadata sync is silent', () {
    final manager = HistoryManager();
    var notifications = 0;
    void listener() {
      notifications++;
    }

    manager.addListener(listener);
    addTearDown(() => manager.removeListener(listener));
    manager.addHistory(
      History.fromMap({
        'type': 'picacg'.hashCode,
        'sourceKey': 'source-cover-sync',
        'id': 'comic-unchanged',
        'title': 'Title',
        'subtitle': 'Author',
        'cover': 'https://example.test/cover.jpg',
        'time': DateTime(2026, 6, 4).millisecondsSinceEpoch,
        'ep': 1,
        'page': 2,
        'max_page': 12,
        'readEpisode': ['1'],
      }),
      notify: false,
    );

    final changed = manager.updateExistingHistoryMetadata(
      const _TestHistoryMetadata(
        sourceKey: 'source-cover-sync',
        id: 'comic-unchanged',
        title: 'Title',
        subTitle: 'Author',
        cover: 'https://example.test/cover.jpg',
        maxPage: 12,
      ),
    );

    expect(changed, isFalse);
    expect(notifications, 0);
  });

  test('History.fromMap normalizes mixed legacy field types', () {
    final history = History.fromMap({
      'type': '0',
      'sourceKey': '',
      'id': 123,
      'title': 456,
      'subtitle': null,
      'cover': 789,
      'time': 'bad',
      'ep': '3',
      'page': 4.8,
      'group': '2',
      'max_page': '10',
      'readEpisode': [1, null, '2-3'],
    });

    expect(history.type, ComicType.local);
    expect(history.sourceKey, 'local');
    expect(history.id, '123');
    expect(history.title, '456');
    expect(history.subtitle, '');
    expect(history.cover, '789');
    expect(history.time.millisecondsSinceEpoch, 0);
    expect(history.ep, 3);
    expect(history.page, 4);
    expect(history.group, 2);
    expect(history.maxPage, 10);
    expect(history.readEpisode, {'1', '2-3'});
  });

  test('History.fromRow tolerates JSON readEpisode and scalar DB values', () {
    final db = sqlite3.open('${tempDir.path}/history.db');
    addTearDown(db.close);
    db.execute(
      '''
      insert or replace into history
        (id, source_key, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        'legacy-row',
        '',
        123,
        456,
        789,
        'bad',
        '0',
        '5',
        6.8,
        jsonEncode([7, null, '8-9']),
        '11',
        '3',
      ],
    );

    final history = HistoryManager().getAll().firstWhere(
      (element) => element.id == 'legacy-row',
    );

    expect(history.sourceKey, 'local');
    expect(history.title, '123');
    expect(history.subtitle, '456');
    expect(history.cover, '789');
    expect(history.time.millisecondsSinceEpoch, 0);
    expect(history.ep, 5);
    expect(history.page, 6);
    expect(history.readEpisode, {'7', '8-9'});
    expect(history.maxPage, 11);
    expect(history.group, 3);
  });

  test('ImageFavoriteManager skips corrupt rows without hiding valid rows', () {
    final db = sqlite3.open('${tempDir.path}/history.db');
    addTearDown(db.close);
    db.execute(
      '''
      insert or replace into image_favorites
        (id, title, sub_title, author, tags, translated_tags, time, max_page, source_key, image_favorites_ep, other)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        'image-bad',
        'Bad',
        '',
        '',
        '',
        '',
        0,
        0,
        'source-image',
        'not json',
        '{}',
      ],
    );
    db.execute(
      '''
      insert or replace into image_favorites
        (id, title, sub_title, author, tags, translated_tags, time, max_page, source_key, image_favorites_ep, other)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        'image-valid',
        123,
        456,
        789,
        'tag:a,,tag:b',
        null,
        'bad',
        '9',
        'source-image',
        jsonEncode([
          {
            'eid': 100,
            'ep': '2',
            'epName': 300,
            'maxPage': '5',
            'imageFavorites': [
              {'page': '1', 'imageKey': 400, 'isAutoFavorite': 'true'},
              {'page': 0, 'imageKey': 'skip'},
            ],
          },
        ]),
        jsonEncode({'1': 'numeric key'}),
      ],
    );

    final comics = ImageFavoriteManager().getAll();

    expect(comics, hasLength(1));
    final comic = comics.single;
    expect(comic.id, 'image-valid');
    expect(comic.title, '123');
    expect(comic.subTitle, '456');
    expect(comic.author, '789');
    expect(comic.tags, ['tag:a', 'tag:b']);
    expect(comic.translatedTags, isEmpty);
    expect(comic.time.millisecondsSinceEpoch, 0);
    expect(comic.maxPage, 9);
    expect(comic.other, {'1': 'numeric key'});
    expect(comic.imageFavoritesEp, hasLength(1));
    expect(comic.imageFavoritesEp.single.eid, '100');
    expect(comic.imageFavoritesEp.single.ep, 2);
    expect(comic.imageFavoritesEp.single.epName, '300');
    expect(comic.imageFavoritesEp.single.maxPage, 5);
    expect(comic.imageFavoritesEp.single.isHasFirstPage, isTrue);
    expect(comic.imageFavoritesEp.single.imageFavorites, hasLength(1));
    expect(comic.imageFavoritesEp.single.imageFavorites.single.imageKey, '400');
    expect(
      comic.imageFavoritesEp.single.imageFavorites.single.isAutoFavorite,
      isTrue,
    );
  });

  test('async history write lock is released after a failed write', () async {
    final manager = HistoryManager();
    manager.close();

    await expectLater(
      manager.addHistoryAsync(
        History.fromMap({
          'type': 'picacg'.hashCode,
          'sourceKey': 'source-async',
          'id': 'comic-failed-async',
          'title': 'Failed Async',
          'subtitle': '',
          'cover': '',
          'time': DateTime(2026).millisecondsSinceEpoch,
          'ep': 1,
          'page': 1,
          'max_page': 9,
          'readEpisode': ['1'],
        }),
      ),
      throwsA(anything),
    );

    await manager.init();
    await manager
        .addHistoryAsync(
          History.fromMap({
            'type': 'picacg'.hashCode,
            'sourceKey': 'source-async',
            'id': 'comic-after-failed-async',
            'title': 'After Failed Async',
            'subtitle': '',
            'cover': '',
            'time': DateTime(2026, 2).millisecondsSinceEpoch,
            'ep': 1,
            'page': 2,
            'max_page': 9,
            'readEpisode': ['1'],
          }),
        )
        .timeout(const Duration(seconds: 2));

    expect(
      manager.findBySourceKey('comic-after-failed-async', 'source-async')?.page,
      2,
    );
  });

  test('reinitializing history opens the existing database again', () async {
    final history = HistoryManager();
    history.close();
    final dbPath = File('${tempDir.path}/history.db');
    if (await dbPath.exists()) {
      await dbPath.delete();
    }
    final db = sqlite3.open(dbPath.path);
    db.execute(
      'create table history (id text primary key, title text, subtitle text, cover text, time int, type int, ep int, page int, readEpisode text, max_page int, chapter_group int);',
    );
    db.execute(
      'insert into history values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'comic-2',
        'Title',
        '',
        '',
        DateTime(2024).millisecondsSinceEpoch,
        'picacg'.hashCode,
        1,
        1,
        '1',
        10,
        null,
      ],
    );
    db.close();

    await history.init();
    expect(history.find('comic-2', ComicType('picacg'.hashCode)), isNotNull);
  });

  test(
    'reinitializing history recovers an interrupted schema migration',
    () async {
      final history = HistoryManager();
      history.close();
      final dbPath = File('${tempDir.path}/history.db');
      if (await dbPath.exists()) {
        await dbPath.delete();
      }

      final db = sqlite3.open(dbPath.path);
      db.execute('''
      create table history (
        id text not null,
        source_key text not null,
        title text,
        subtitle text,
        cover text,
        time int,
        type int,
        ep int,
        page int,
        readEpisode text,
        max_page int,
        chapter_group int,
        primary key (id, source_key)
      );
    ''');
      db.execute('''
      create table history_legacy (
        id text primary key,
        title text,
        subtitle text,
        cover text,
        time int,
        type int,
        ep int,
        page int,
        readEpisode text,
        max_page int,
        chapter_group int
      );
    ''');
      db.execute(
        'insert into history_legacy values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          'comic-legacy',
          'Legacy Title',
          '',
          '',
          DateTime(2024).millisecondsSinceEpoch,
          'picacg'.hashCode,
          4,
          6,
          '4',
          20,
          2,
        ],
      );
      db.close();

      await history.init();

      final recoveredDb = sqlite3.open(dbPath.path);
      final legacyTables = recoveredDb.select(
        "select name from sqlite_master where type = 'table' and name = 'history_legacy';",
      );
      final rows = recoveredDb.select(
        'select id, ep, page, chapter_group from history where id = ?;',
        ['comic-legacy'],
      );
      recoveredDb.close();

      expect(legacyTables, isEmpty);
      expect(rows, isNotEmpty);
      expect(rows.first['ep'], 4);
      expect(rows.first['page'], 6);
      expect(rows.first['chapter_group'], 2);
    },
  );

  test('exportAppData packages the latest reading progress', () async {
    await File('${tempDir.path}/appdata.json').writeAsString(
      jsonEncode({
        'settings': <String, dynamic>{},
        'searchHistory': <String>[],
      }),
    );
    await File('${tempDir.path}/cookie.db').writeAsBytes([]);
    await File('${tempDir.path}/local_favorite.db').writeAsBytes([]);
    await Directory('${tempDir.path}/comic_source').create(recursive: true);

    HistoryManager().addHistory(
      History.fromMap({
        'type': 'picacg'.hashCode,
        'sourceKey': 'source-export',
        'id': 'comic-export',
        'title': 'Exported',
        'subtitle': '',
        'cover': '',
        'time': DateTime(2025).millisecondsSinceEpoch,
        'ep': 7,
        'page': 13,
        'group': 2,
        'max_page': 19,
        'readEpisode': ['2-7'],
      })..group = 2,
    );

    final exported = await exportAppData(false);
    final extractDir = await Directory.systemTemp.createTemp(
      'venera-history-export-extract-',
    );
    await Isolate.run(() {
      ZipFile.openAndExtract(exported.path, extractDir.path);
    });

    final db = sqlite3.open('${extractDir.path}/history.db');
    final rows = db.select(
      'select id, source_key, ep, page, chapter_group from history where id = ? and source_key = ?;',
      ['comic-export', 'source-export'],
    );
    db.close();

    expect(rows, isNotEmpty);
    expect(rows.first['ep'], 7);
    expect(rows.first['page'], 13);
    expect(rows.first['chapter_group'], 2);

    await extractDir.delete(recursive: true);
  });

  test(
    'importAppData makes imported reading progress immediately available',
    () async {
      final sourceDir = await Directory.systemTemp.createTemp(
        'venera-history-import-src-',
      );
      final zipPath = '${sourceDir.path}/import.venera';
      final historyDbPath = '${sourceDir.path}/history.db';
      final appdataPath = '${sourceDir.path}/appdata.json';

      final db = sqlite3.open(historyDbPath);
      db.execute('''
      create table history (
        id text not null,
        source_key text not null,
        title text,
        subtitle text,
        cover text,
        time int,
        type int,
        ep int,
        page int,
        readEpisode text,
        max_page int,
        chapter_group int,
        primary key (id, source_key)
      );
    ''');
      db.execute(
        'insert into history values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          'comic-import',
          'source-import',
          'Imported',
          '',
          '',
          DateTime(2025).millisecondsSinceEpoch,
          'picacg'.hashCode,
          9,
          21,
          '3-9',
          30,
          3,
        ],
      );
      db.close();

      await File(appdataPath).writeAsString(
        jsonEncode({
          'settings': <String, dynamic>{},
          'searchHistory': <String>[],
        }),
      );

      final zip = ZipFile.open(zipPath);
      zip.addFile('history.db', historyDbPath);
      zip.addFile('appdata.json', appdataPath);
      zip.close();

      final targetDataDir = await Directory.systemTemp.createTemp(
        'venera-history-import-data-',
      );
      final targetCacheDir = await Directory.systemTemp.createTemp(
        'venera-history-import-cache-',
      );
      App.dataPath = targetDataDir.path;
      App.cachePath = targetCacheDir.path;
      await importAppData(File(zipPath));

      final imported = HistoryManager().findBySourceKey(
        'comic-import',
        'source-import',
      );
      expect(imported, isNotNull);
      expect(imported!.ep, 9);
      expect(imported.page, 21);
      expect(imported.group, 3);
      expect(imported.maxPage, 30);
      expect(imported.readEpisode, contains('3-9'));

      HistoryManager().close();
      await sourceDir.delete(recursive: true);
      await targetDataDir.delete(recursive: true);
      await targetCacheDir.delete(recursive: true);
    },
  );
}

class _TestHistoryMetadata with HistoryMixin {
  const _TestHistoryMetadata({
    required this.sourceKey,
    required this.id,
    required this.title,
    required this.subTitle,
    required this.cover,
    required this.maxPage,
  });

  @override
  final String sourceKey;

  @override
  final String id;

  @override
  final String title;

  @override
  final String? subTitle;

  @override
  final String cover;

  @override
  final int? maxPage;

  @override
  HistoryType get historyType => HistoryType(sourceKey.hashCode);
}
