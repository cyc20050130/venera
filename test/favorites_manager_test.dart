import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late Directory tempDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'venera-favorites-manager-',
    );
    App.dataPath = tempDir.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return tempDir.path;
          }
          return null;
        });
    LocalFavoritesManager.cache?.close();
    LocalFavoritesManager.cache = null;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    LocalFavoritesManager.cache?.close();
    LocalFavoritesManager.cache = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'manager init skips malformed favorite hash rows and order values',
    () async {
      final db = sqlite3.open('${tempDir.path}/local_favorite.db');
      db
        ..execute('''
        create table folder_order (
          folder_name text primary key,
          order_value int
        );
      ''')
        ..execute('''
        create table folder_sync (
          folder_name text primary key,
          source_key text,
          source_folder text
        );
      ''')
        ..execute('''
        create table "Folder"(
          id text,
          name TEXT,
          author TEXT,
          type int,
          tags TEXT,
          cover_path TEXT,
          time TEXT,
          display_order int,
          translated_tags TEXT,
          primary key (id, type)
        );
      ''')
        ..execute(
          'insert into folder_order (folder_name, order_value) values (?, ?);',
          ['Folder', 'bad-order'],
        )
        ..execute(
          '''
        insert into "Folder" (
          id,
          name,
          author,
          type,
          tags,
          cover_path,
          time,
          display_order,
          translated_tags
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
          ['comic-valid', 'Valid', 'Author', '7', '[]', 'cover', '', 0, ''],
        )
        ..execute(
          '''
        insert into "Folder" (
          id,
          name,
          author,
          type,
          tags,
          cover_path,
          time,
          display_order,
          translated_tags
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
          ['comic-bad', 'Bad', 'Author', 'bad', '[]', 'cover', '', 1, ''],
        )
        ..close();

      final manager = LocalFavoritesManager();
      await manager.init();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(manager.folderNames, ['Folder']);
      expect(manager.totalComics, 1);
    },
  );

  test('manager init skips unsafe legacy favorite table names', () async {
    final db = sqlite3.open('${tempDir.path}/local_favorite.db');
    db
      ..execute('''
        create table folder_order (
          folder_name text primary key,
          order_value int
        );
      ''')
      ..execute('''
        create table folder_sync (
          folder_name text primary key,
          source_key text,
          source_folder text
        );
      ''')
      ..execute('''
        create table "Bad""Folder"(
          id text,
          name TEXT,
          author TEXT,
          type int,
          tags TEXT,
          cover_path TEXT,
          time TEXT,
          display_order int,
          translated_tags TEXT,
          primary key (id, type)
        );
      ''')
      ..close();

    final manager = LocalFavoritesManager();
    await manager.init();

    expect(manager.folderNames, isEmpty);
  });

  test('folder import sanitizes unsafe names', () async {
    final manager = LocalFavoritesManager();
    await manager.init();

    expect(() => manager.createFolder('bad"name'), throwsA('Invalid name'));
    expect(() => manager.createFolder('folder_order'), throwsA('Invalid name'));

    manager.fromJson(jsonEncode({'name': 'bad"name', 'comics': []}));

    expect(manager.folderNames, ['bad_name']);
  });
}
