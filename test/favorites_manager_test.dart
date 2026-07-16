import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
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

  test('favorite folder display order uses a dedicated index', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('''
      CREATE TABLE "Folder" (
        id TEXT,
        type INTEGER,
        display_order INTEGER,
        PRIMARY KEY (id, type)
      );
    ''');

    LocalFavoritesManager.ensureFolderIndexes(db, ['Folder']);

    final indexNames = db
        .select("PRAGMA index_list('Folder');")
        .map((row) => row['name'])
        .whereType<String>()
        .where((name) => name.startsWith('favorite_display_order_'))
        .toList();
    expect(indexNames, hasLength(1));
    final plan = db.select(
      'EXPLAIN QUERY PLAN SELECT * FROM "Folder" ORDER BY display_order;',
    );
    expect(
      plan.map((row) => row['detail'].toString()).join(' '),
      contains(indexNames.single),
    );
  });

  test('favorite identity cache cannot report XOR hash collisions', () async {
    final manager = LocalFavoritesManager();
    await manager.init();
    manager.createFolder('Folder');
    const firstId = 'first-comic';
    const secondId = 'second-comic';
    const firstType = 73;
    final collidingType = firstId.hashCode ^ firstType ^ secondId.hashCode;
    expect(collidingType, isNot(firstType));

    manager.addComic(
      'Folder',
      FavoriteItem(
        id: firstId,
        name: 'First',
        coverPath: '',
        author: '',
        type: const ComicType(firstType),
        tags: const [],
      ),
    );

    expect(manager.isExist(firstId, const ComicType(firstType)), isTrue);
    expect(manager.isExist(secondId, ComicType(collidingType)), isFalse);
  });

  test(
    'single and batch moves preserve extended fields and refresh counts',
    () async {
      final manager = LocalFavoritesManager();
      await manager.init();
      manager.createFolder('Source');
      manager.createFolder('Target');
      manager.prepareTableForFollowUpdates('Source');
      manager.prepareTableForFollowUpdates('Target');
      const type = ComicType(91);
      for (final id in const ['comic-1', 'comic-2']) {
        manager.addComic(
          'Source',
          FavoriteItem(
            id: id,
            name: id,
            coverPath: '$id.jpg',
            author: 'Author',
            type: type,
            tags: const ['tag'],
          ),
        );
      }
      final db = sqlite3.open('${tempDir.path}/local_favorite.db');
      try {
        for (var index = 1; index <= 2; index++) {
          db.execute(
            '''
          update "Source"
          set translated_tags = ?, last_update_time = ?,
              has_new_update = ?, last_check_time = ?
          where id = ? and type = ?;
          ''',
            [
              'translated-$index',
              'update-$index',
              index % 2,
              100 + index,
              'comic-$index',
              type.value,
            ],
          );
        }
      } finally {
        db.close();
      }

      manager.moveFavorite('Source', 'Target', 'comic-1', type);
      manager.batchMoveFavorites('Source', 'Target', [
        FavoriteItem(
          id: 'comic-2',
          name: 'comic-2',
          coverPath: 'comic-2.jpg',
          author: 'Author',
          type: type,
          tags: const ['tag'],
        ),
      ]);

      expect(manager.folderComics('Source'), 0);
      expect(manager.folderComics('Target'), 2);
      final verificationDb = sqlite3.open('${tempDir.path}/local_favorite.db');
      try {
        final rows = verificationDb.select(
          'select * from "Target" order by id;',
        );
        expect(rows, hasLength(2));
        for (var index = 1; index <= 2; index++) {
          final row = rows[index - 1];
          expect(row['translated_tags'], 'translated-$index');
          expect(row['last_update_time'], 'update-$index');
          expect(row['has_new_update'], index % 2);
          expect(row['last_check_time'], 100 + index);
        }
      } finally {
        verificationDb.close();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    },
  );
}
