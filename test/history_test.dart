import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/data.dart';
import 'package:zip_flutter/zip_flutter.dart';

DynamicLibrary _openTestSqlite() {
  return DynamicLibrary.open(
    'D:/code/projects/venera/build/test-sqlite3/sqlite3.dll',
  );
}

const _zipDllSource =
    'D:/code/projects/venera/build/test-zip/shared/zip_flutter.dll';

void main() {
  late Directory tempDir;
  late Directory tempCacheDir;
  late Directory zipDllDir;
  late String originalCurrentDir;

  setUpAll(() async {
    open.overrideFor(OperatingSystem.windows, _openTestSqlite);
    final source = File(_zipDllSource);
    if (!source.existsSync()) {
      throw StateError(
        'Missing test zip dll at $_zipDllSource. Build it before running history tests.',
      );
    }
    originalCurrentDir = Directory.current.path;
    zipDllDir = await Directory.systemTemp.createTemp('venera-history-zip-');
    source.copySync('${zipDllDir.path}/zip_flutter.dll');
    Directory.current = zipDllDir.path;
  });

  tearDownAll(() {
    Directory.current = originalCurrentDir;
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
    db.dispose();

    await history.init();
    expect(history.find('comic-2', ComicType('picacg'.hashCode)), isNotNull);
  });

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
    db.dispose();

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
      db.dispose();

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
