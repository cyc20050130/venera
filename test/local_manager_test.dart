import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/image_provider/local_favorite_image.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/images.dart';

void main() {
  late Directory tempDir;
  late LocalManager manager;
  late bool managerInitialized;

  File snapshotFile() => File('${tempDir.path}/downloading_tasks.json');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-local-test-');
    App.dataPath = tempDir.path;
    LocalManager.debugResetInstance();
    manager = LocalManager();
    managerInitialized = false;
    manager.downloadingTasks.clear();
    ComicSourceManager().remove('test-source');
    if (await snapshotFile().exists()) {
      await snapshotFile().delete();
    }
  });

  tearDown(() async {
    manager.downloadingTasks.clear();
    ComicSourceManager().remove('test-source');
    await manager.flushCurrentDownloadingTasks();
    if (managerInitialized) {
      manager.dispose();
      LocalManager.debugResetInstance();
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (await tempDir.exists()) {
      for (var i = 0; i < 5; i++) {
        try {
          await tempDir.delete(recursive: true);
          break;
        } on PathAccessException {
          if (i == 4) rethrow;
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  });

  test('archive download temp paths are operation scoped', () {
    final firstArchive = buildArchiveDownloadFilePath(tempDir.path, 'op-a');
    final secondArchive = buildArchiveDownloadFilePath(tempDir.path, 'op-b');
    final firstExtract = buildArchiveExtractCacheDirectory(
      tempDir.path,
      'op-a',
    );
    final secondExtract = buildArchiveExtractCacheDirectory(
      tempDir.path,
      'op-b',
    );

    expect(firstArchive, isNot(secondArchive));
    expect(firstExtract, isNot(secondExtract));
    expect(
      firstArchive,
      isNot('${tempDir.path}${Platform.pathSeparator}archive_downloading.zip'),
    );
    expect(
      firstExtract,
      isNot('${tempDir.path}${Platform.pathSeparator}archive_downloading'),
    );
    expect(firstArchive, endsWith('archive_downloading-op-a.zip'));
    expect(firstExtract, endsWith('archive_downloading-op-a'));
  });

  test(
    'deleting an external local entry never deletes external files',
    () async {
      await manager.init();
      managerInitialized = true;
      final external = await Directory.systemTemp.createTemp(
        'venera-external-comic-',
      );
      addTearDown(() => external.delete(recursive: true));
      final marker = File('${external.path}/keep.txt')
        ..writeAsStringSync('keep');
      final comic = LocalComic(
        id: 'external-comic',
        title: 'External comic',
        subtitle: '',
        tags: const [],
        directory: external.path,
        chapters: null,
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime(2026, 7, 16),
      );
      await manager.add(comic);

      manager.batchDeleteComicsKeepFavoritesAndHistory([comic]);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(manager.find(comic.id, comic.comicType), isNull);
      expect(marker.existsSync(), isTrue);
    },
  );

  test('scheduled task snapshots keep only the latest queued state', () async {
    manager.downloadingTasks.add(_FakeDownloadTask('first'));
    final firstSave = manager.scheduleSaveCurrentDownloadingTasks(
      delay: const Duration(milliseconds: 120),
    );

    await Future.delayed(const Duration(milliseconds: 20));
    manager.downloadingTasks
      ..clear()
      ..add(_FakeDownloadTask('second'));
    final secondSave = manager.scheduleSaveCurrentDownloadingTasks(
      delay: const Duration(milliseconds: 120),
    );

    await Future.wait([firstSave, secondSave]);

    final json =
        jsonDecode(await snapshotFile().readAsString()) as List<dynamic>;
    expect(json, hasLength(1));
    expect((json.first as Map<String, dynamic>)['id'], 'second');
  });

  test('flushCurrentDownloadingTasks writes immediately', () async {
    manager.downloadingTasks.add(_FakeDownloadTask('flush-now'));

    manager.scheduleSaveCurrentDownloadingTasks(
      delay: const Duration(seconds: 30),
    );
    await manager.flushCurrentDownloadingTasks();

    expect(await snapshotFile().exists(), isTrue);
    final json =
        jsonDecode(await snapshotFile().readAsString()) as List<dynamic>;
    expect(json, hasLength(1));
    expect((json.first as Map<String, dynamic>)['id'], 'flush-now');
  });

  test(
    'downloading task snapshot writer skips already persisted snapshots',
    () async {
      var writeAttempts = 0;
      manager.debugBeforeDownloadingTasksSnapshotWrite = () {
        writeAttempts++;
        return Future<void>.value();
      };

      manager.downloadingTasks.add(_FakeDownloadTask('snapshot-once'));
      await manager.flushCurrentDownloadingTasks();
      await manager.flushCurrentDownloadingTasks();

      expect(writeAttempts, 1);

      manager.downloadingTasks
        ..clear()
        ..add(_FakeDownloadTask('snapshot-updated'));
      await manager.flushCurrentDownloadingTasks();

      expect(writeAttempts, 2);
    },
  );

  test(
    'background downloading task snapshot save swallows write failures',
    () async {
      final writeAttempted = Completer<void>();
      manager.debugBeforeDownloadingTasksSnapshotWrite = () {
        if (!writeAttempted.isCompleted) {
          writeAttempted.complete();
        }
        throw StateError('snapshot boom');
      };
      addTearDown(
        () => manager.debugBeforeDownloadingTasksSnapshotWrite = null,
      );

      manager.saveCurrentDownloadingTasksInBackground(reason: 'test failure');

      await writeAttempted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      manager.debugBeforeDownloadingTasksSnapshotWrite = null;
      await manager.flushCurrentDownloadingTasks();
    },
  );

  test(
    'concurrent flushCurrentDownloadingTasks calls share one in-flight write',
    () async {
      manager.downloadingTasks.add(_FakeDownloadTask('flush-shared'));

      final firstFlush = manager.flushCurrentDownloadingTasks();
      final secondFlush = manager.flushCurrentDownloadingTasks();

      expect(identical(firstFlush, secondFlush), isTrue);

      await Future.wait([firstFlush, secondFlush]);

      final json =
          jsonDecode(await snapshotFile().readAsString()) as List<dynamic>;
      expect(json, hasLength(1));
      expect((json.first as Map<String, dynamic>)['id'], 'flush-shared');
    },
  );

  test(
    'flushCurrentDownloadingTasks writes latest state when requested during an in-flight write',
    () async {
      final writeGate = Completer<void>();
      var writeAttempts = 0;
      manager.debugBeforeDownloadingTasksSnapshotWrite = () {
        writeAttempts++;
        if (writeAttempts == 1) {
          return writeGate.future;
        }
        return Future<void>.value();
      };

      manager.downloadingTasks.add(_FakeDownloadTask('flush-old'));
      final firstFlush = manager.flushCurrentDownloadingTasks();
      await Future<void>.delayed(Duration.zero);

      manager.downloadingTasks
        ..clear()
        ..add(_FakeDownloadTask('flush-new'));
      final secondFlush = manager.flushCurrentDownloadingTasks();

      writeGate.complete();
      await secondFlush;
      await firstFlush;

      final json =
          jsonDecode(await snapshotFile().readAsString()) as List<dynamic>;
      expect(json, hasLength(1));
      expect((json.first as Map<String, dynamic>)['id'], 'flush-new');
      expect(writeAttempts, 2);
    },
  );

  test('moveToFirst ignores missing downloading tasks', () {
    final existing = _FakeDownloadTask('existing');
    final missing = _FakeDownloadTask('missing');

    expect(() => manager.moveToFirst(missing), returnsNormally);

    manager.downloadingTasks.add(existing);
    expect(() => manager.moveToFirst(missing), returnsNormally);
    expect(manager.downloadingTasks.single.id, 'existing');
  });

  test('findValidId ignores nonnumeric legacy local ids', () async {
    await manager.init();
    managerInitialized = true;

    await manager.add(
      LocalComic(
        id: 'legacy-id',
        title: 'Legacy Comic',
        subtitle: '',
        tags: const [],
        directory: 'legacy-id',
        chapters: null,
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime(2026, 6, 4),
      ),
    );
    expect(manager.findValidId(ComicType.local), '1');

    await manager.add(
      LocalComic(
        id: '7',
        title: 'Numeric Comic',
        subtitle: '',
        tags: const [],
        directory: '7',
        chapters: null,
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime(2026, 6, 4),
      ),
    );
    expect(manager.findValidId(ComicType.local), '8');
  });

  test('local database indexes cover list and numeric id queries', () async {
    await manager.init();
    managerInitialized = true;

    final db = sqlite3.open('${tempDir.path}/local.db');
    addTearDown(db.close);
    final indexes = db
        .select("PRAGMA index_list('comics');")
        .map((row) => row['name'])
        .whereType<String>()
        .toSet();

    expect(indexes, contains('comics_created_at_index'));
    expect(indexes, contains('comics_title_index'));
    expect(indexes, contains('comics_directory_index'));
    expect(indexes, contains('comics_numeric_id_index'));

    final recentPlan = db.select(
      'EXPLAIN QUERY PLAN SELECT * FROM comics ORDER BY created_at DESC LIMIT 20;',
    );
    expect(
      recentPlan.map((row) => row['detail'].toString()).join(' '),
      contains('comics_created_at_index'),
    );
    final idPlan = db.select(
      'EXPLAIN QUERY PLAN SELECT id FROM comics WHERE comic_type = 0 '
      'ORDER BY CAST(id AS INTEGER) DESC LIMIT 1;',
    );
    expect(
      idPlan.map((row) => row['detail'].toString()).join(' '),
      contains('comics_numeric_id_index'),
    );
  });

  test('find tolerates malformed legacy local comic row fields', () async {
    await manager.init();
    managerInitialized = true;

    final db = sqlite3.open('${tempDir.path}/local.db');
    addTearDown(db.close);
    db.execute(
      'INSERT OR REPLACE INTO comics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        'legacy-corrupt',
        123,
        456,
        'not json',
        'legacy-dir',
        '{"group":{"2":2}}',
        789,
        '0',
        jsonEncode([1, null, 'ep']),
        null,
      ],
    );

    final comic = manager.find('legacy-corrupt', ComicType.local);

    expect(comic, isNotNull);
    expect(comic!.title, '123');
    expect(comic.subtitle, '456');
    expect(comic.tags, isEmpty);
    expect(comic.chapters?.isGrouped, isTrue);
    expect(comic.chapters?.getGroup('group'), {'2': '2'});
    expect(comic.cover, '789');
    expect(comic.downloadedChapters, ['1', 'ep']);
    expect(comic.createdAt.millisecondsSinceEpoch, 0);
  });

  test('batchDeleteComics can keep favorites and history entries', () async {
    await manager.init();
    managerInitialized = true;
    final comic = LocalComic(
      id: 'comic-1',
      title: 'Local Comic',
      subtitle: 'Author',
      tags: const ['tag'],
      directory: 'comic-1',
      chapters: null,
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: const [],
      createdAt: DateTime(2026, 5, 22),
    );
    await manager.add(comic);

    final favoritesDb = sqlite3.open('${tempDir.path}/local_favorite.db');
    favoritesDb.execute('''
      create table if not exists folder_order (
        folder_name text primary key,
        order_value int
      );
    ''');
    favoritesDb.execute('''
      create table if not exists folder_sync (
        folder_name text primary key,
        source_key text,
        source_folder text
      );
    ''');
    favoritesDb.execute('''
      create table "默认收藏"(
        id text,
        name text,
        author text,
        type int,
        tags text,
        cover_path text,
        time text,
        display_order int,
        translated_tags text,
        primary key (id, type)
      );
    ''');
    favoritesDb.execute(
      '''
      insert into "默认收藏"
        (id, name, author, type, tags, cover_path, time, display_order, translated_tags)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''',
      [
        comic.id,
        comic.title,
        comic.subtitle,
        comic.comicType.value,
        comic.tags.join(','),
        comic.cover,
        '2026-05-22 00:00:00',
        0,
        '',
      ],
    );

    final historyDb = sqlite3.open('${tempDir.path}/history.db');
    historyDb.execute('''
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
    historyDb.execute(
      '''
      insert into history
        (id, source_key, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    ''',
      [
        comic.id,
        'local',
        comic.title,
        comic.subtitle,
        comic.cover,
        DateTime(2026, 5, 22).millisecondsSinceEpoch,
        comic.comicType.value,
        1,
        1,
        '',
        null,
        null,
      ],
    );

    manager.batchDeleteComics([comic], false, false);

    expect(manager.find(comic.id, comic.comicType), isNull);
    expect(
      favoritesDb.select(
        'select count(*) as c from "默认收藏" where id = ? and type = ?;',
        [comic.id, comic.comicType.value],
      ).first['c'],
      1,
    );
    expect(
      historyDb.select(
        'select count(*) as c from history where id = ? and source_key = ?;',
        [comic.id, 'local'],
      ).first['c'],
      1,
    );

    favoritesDb.close();
    historyDb.close();
  });

  test('batched downloaded state repair notifies once after changes', () async {
    await manager.init();
    managerInitialized = true;
    var notifications = 0;
    void listener() {
      notifications++;
    }

    manager.addListener(listener);
    addTearDown(() => manager.removeListener(listener));

    final comicDir = Directory('${tempDir.path}/comic-batched');
    final validChapterDir = Directory('${comicDir.path}/valid');
    await validChapterDir.create(recursive: true);
    await File('${validChapterDir.path}/001.jpg').writeAsBytes([1, 2, 3]);

    final comic = LocalComic(
      id: 'comic-batched',
      title: 'Batched Comic',
      subtitle: 'Author',
      tags: const ['tag'],
      directory: comicDir.path,
      chapters: ComicChapters({'valid': 'Valid', 'missing': 'Missing'}),
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: const ['valid', 'missing'],
      createdAt: DateTime(2026, 6, 2),
    );
    await manager.add(comic);
    notifications = 0;

    await manager.repairAllDownloadedStateBatched(batchSize: 1);

    expect(notifications, 1);
    expect(manager.find(comic.id, comic.comicType)?.downloadedChapters, [
      'valid',
    ]);
  });

  test('getImages rejects out of range local chapter index', () async {
    await manager.init();
    managerInitialized = true;
    final comicDir = Directory('${tempDir.path}/comic-invalid-ep');
    final chapterDir = Directory('${comicDir.path}/ep-1');
    await chapterDir.create(recursive: true);
    await File('${chapterDir.path}/001.jpg').writeAsBytes([1, 2, 3]);

    final comic = LocalComic(
      id: 'comic-invalid-ep',
      title: 'Invalid Ep Comic',
      subtitle: 'Author',
      tags: const ['tag'],
      directory: comicDir.path,
      chapters: ComicChapters({'ep-1': 'Episode 1'}),
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: const ['ep-1'],
      createdAt: DateTime(2026, 6, 4),
    );
    await manager.add(comic);

    await expectLater(
      manager.getImages(comic.id, comic.comicType, 2),
      throwsA('Invalid ep'),
    );
  });

  test(
    'image favorite provider reads downloaded local chapter image',
    () async {
      await manager.init();
      managerInitialized = true;
      final comicDir = Directory('${tempDir.path}/comic-image-favorite');
      final chapterDir = Directory('${comicDir.path}/ep-1');
      await chapterDir.create(recursive: true);
      await File('${comicDir.path}/cover.jpg').writeAsBytes([0]);
      await File('${chapterDir.path}/001.jpg').writeAsBytes([1, 2, 3]);
      await File('${chapterDir.path}/002.jpg').writeAsBytes([4, 5, 6]);

      final comic = LocalComic(
        id: 'comic-image-favorite',
        title: 'Image Favorite Comic',
        subtitle: 'Author',
        tags: const ['tag'],
        directory: comicDir.path,
        chapters: ComicChapters({'ep-1': 'Episode 1'}),
        cover: 'cover.jpg',
        comicType: ComicType.fromKey('test-source'),
        downloadedChapters: const ['ep-1'],
        createdAt: DateTime(2026, 6, 4),
      );
      await manager.add(comic);

      final provider = ImageFavoritesProvider(
        ImageFavorite(
          2,
          'network-image-key',
          null,
          'ep-1',
          comic.id,
          1,
          'test-source',
          'Episode 1',
        ),
      );

      expect(await provider.getImageFromLocal(), [4, 5, 6]);
    },
  );

  test('image favorite provider uses matching cache key for delete', () async {
    App.cachePath = tempDir.path;
    final favorite = ImageFavorite(
      1,
      'network-image-key',
      null,
      'ep-1',
      'comic-cache-favorite',
      1,
      'test-source',
      'Episode 1',
    );
    final provider = ImageFavoritesProvider(favorite);

    await provider.writeToCache(Uint8List.fromList([1, 2, 3]));
    expect(await provider.readFromCache(), [1, 2, 3]);

    await ImageFavoritesProvider.deleteFromCache(favorite);
    expect(await provider.readFromCache(), isNull);
  });

  test('image favorite provider ignores empty cache files', () async {
    App.cachePath = tempDir.path;
    final provider = ImageFavoritesProvider(
      ImageFavorite(
        1,
        'network-image-key',
        null,
        'ep-1',
        'comic-empty-cache-favorite',
        1,
        'test-source',
        'Episode 1',
      ),
    );

    await provider.writeToCache(Uint8List(0));

    expect(await provider.readFromCache(), isNull);
  });

  test('image favorite provider rejects out of range source pages', () async {
    final source = _buildSource();
    ComicSourceManager().add(source);
    final provider = ImageFavoritesProvider(
      ImageFavorite(
        2,
        '',
        null,
        'ep-1',
        'comic-page-range-favorite',
        1,
        'test-source',
        'Episode 1',
      ),
    );

    await expectLater(
      provider.getImageKey(),
      throwsA(contains('out of range')),
    );
  });

  test('local favorite cover cache ignores and deletes empty files', () async {
    final provider = LocalFavoriteImageProvider(
      'https://example.test/cover.jpg',
      'comic-local-favorite',
      ComicType.local.value,
    );
    final cache = File(
      '${App.dataPath}/favorite_cover/${provider.key.hashCode}',
    );
    await cache.create(recursive: true);

    expect(await readLocalFavoriteCoverCache(provider.key), isNull);
    expect(await cache.exists(), isFalse);
  });

  test('init restores downloading tasks before it completes', () async {
    final source = _buildSource();
    ComicSourceManager().add(source);
    await snapshotFile().writeAsString(
      jsonEncode([
        {
          'type': 'ImagesDownloadTask',
          'source': 'test-source',
          'comicId': 'comic-restore',
          'comic': null,
          'chapters': null,
          'path': null,
          'cover': null,
          'images': null,
          'downloadedCount': 0,
          'totalCount': 0,
          'index': 0,
          'chapter': 0,
          'completedChapters': <String>[],
          'failedChapters': <String>[],
        },
      ]),
    );

    await manager.init();
    managerInitialized = true;

    expect(manager.downloadingTasks, hasLength(1));
    expect(manager.downloadingTasks.first.id, 'comic-restore');
  });

  test(
    'init skips malformed downloading tasks without dropping valid ones',
    () async {
      final source = _buildSource();
      ComicSourceManager().add(source);
      await snapshotFile().writeAsString(
        jsonEncode([
          {
            'type': 'ImagesDownloadTask',
            'source': 'test-source',
            'comicId': null,
          },
          {
            'type': 'ImagesDownloadTask',
            'source': 'test-source',
            'comicId': 'comic-valid-restore',
            'comic': null,
            'chapters': null,
            'path': null,
            'cover': null,
            'images': {
              'ep-1': [1, '2', null],
              'bad': 'skip',
            },
            'downloadedCount': '1',
            'totalCount': '2',
            'index': '0',
            'chapter': 0,
            'completedChapters': [1, 'done'],
            'failedChapters': [2],
          },
          {'type': 'UnknownTask'},
        ]),
      );

      await manager.init();
      managerInitialized = true;
      await manager.flushCurrentDownloadingTasks();

      expect(manager.downloadingTasks, hasLength(1));
      expect(manager.downloadingTasks.first.id, 'comic-valid-restore');

      final restored =
          jsonDecode(await snapshotFile().readAsString()) as List<dynamic>;
      expect(restored, hasLength(1));
      expect(
        (restored.single as Map<String, dynamic>)['comicId'],
        'comic-valid-restore',
      );
      expect(restored.single['images'], {
        'ep-1': ['1', '2'],
      });
      expect(restored.single['downloadedCount'], 1);
      expect(restored.single['totalCount'], 2);
      expect(restored.single['completedChapters'], ['1', 'done']);
      expect(restored.single['failedChapters'], ['2']);
    },
  );

  test(
    'init normalizes invalid download progress and drops out of range rows',
    () async {
      final source = _buildSource();
      ComicSourceManager().add(source);
      await snapshotFile().writeAsString(
        jsonEncode([
          {
            'type': 'ImagesDownloadTask',
            'source': 'test-source',
            'comicId': 'comic-negative-progress',
            'comic': null,
            'images': {
              'ep-1': ['1', '2'],
            },
            'downloadedCount': -5,
            'totalCount': -1,
            'index': -2,
            'chapter': -3,
          },
          {
            'type': 'ImagesDownloadTask',
            'source': 'test-source',
            'comicId': 'comic-out-of-range-progress',
            'comic': null,
            'images': {
              'ep-1': ['1', '2'],
            },
            'downloadedCount': 1,
            'totalCount': 2,
            'index': 3,
            'chapter': 0,
          },
        ]),
      );

      await manager.init();
      managerInitialized = true;
      await manager.flushCurrentDownloadingTasks();

      expect(manager.downloadingTasks, hasLength(1));
      expect(manager.downloadingTasks.first.id, 'comic-negative-progress');

      final restored =
          jsonDecode(await snapshotFile().readAsString()) as List<dynamic>;
      expect(restored, hasLength(1));
      final row = restored.single as Map<String, dynamic>;
      expect(row['comicId'], 'comic-negative-progress');
      expect(row['downloadedCount'], 0);
      expect(row['totalCount'], 0);
      expect(row['index'], 0);
      expect(row['chapter'], 0);
    },
  );

  test(
    'init restores archive download tasks and skips malformed or stale rows',
    () async {
      final source = _buildSource();
      ComicSourceManager().add(source);
      final staleSourceComic = _buildDetails(
        'bad-archive-stale-source',
      ).toJson()..['sourceKey'] = 'deleted-source';
      await snapshotFile().writeAsString(
        jsonEncode([
          {
            'type': 'ArchiveDownloadTask',
            'archiveUrl': '',
            'comic': _buildDetails('bad-archive').toJson(),
          },
          {
            'type': 'ArchiveDownloadTask',
            'archiveUrl': 'https://example.test/deleted-source.zip',
            'comic': staleSourceComic,
          },
          {
            'type': 'ArchiveDownloadTask',
            'archiveUrl': 'https://example.test/archive.zip',
            'comic': _buildDetails('comic-archive-restore').toJson(),
            'path': '${tempDir.path}/archive-path',
          },
        ]),
      );

      await manager.init();
      managerInitialized = true;
      await manager.flushCurrentDownloadingTasks();

      expect(manager.downloadingTasks, hasLength(1));
      expect(manager.downloadingTasks.first, isA<ArchiveDownloadTask>());
      expect(manager.downloadingTasks.first.id, 'comic-archive-restore');

      final restored =
          jsonDecode(await snapshotFile().readAsString()) as List<dynamic>;
      expect(restored, hasLength(1));
      expect(
        (restored.single as Map<String, dynamic>)['type'],
        'ArchiveDownloadTask',
      );
    },
  );

  test('archive download task creation rejects missing sources', () {
    final details = _buildDetails('comic-archive-missing-source');

    expect(
      ArchiveDownloadTask.tryCreate(
        'https://example.test/archive.zip',
        details,
      ),
      isNull,
    );
    expect(
      () => ArchiveDownloadTask('https://example.test/archive.zip', details),
      throwsStateError,
    );

    final source = _buildSource();
    ComicSourceManager().add(source);

    final task = ArchiveDownloadTask.tryCreate(
      'https://example.test/archive.zip',
      details,
    );
    expect(task, isNotNull);
    expect(task!.id, 'comic-archive-missing-source');
    expect(task.comicType, ComicType(source.key.hashCode));
  });

  test(
    'cancelling active image download task wakes pending image waiters',
    () async {
      final source = _buildSource();
      ComicSourceManager().add(source);
      await manager.init();
      managerInitialized = true;

      final deleteDir = await Directory(
        '${tempDir.path}/cancel-active-image-download',
      ).create();
      final imageStarted = Completer<void>();
      final releaseImage = Completer<void>();
      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) async* {
            imageStarted.complete();
            await releaseImage.future;
          };
      addTearDown(() {
        if (!releaseImage.isCompleted) {
          releaseImage.complete();
        }
        ImageDownloader.debugResetReaderImageScheduling();
      });

      final task = ImagesDownloadTask.fromJson({
        'type': 'ImagesDownloadTask',
        'source': 'test-source',
        'comicId': 'comic-cancel-active-download',
        'comic': _buildDetails('comic-cancel-active-download').toJson(),
        'chapters': null,
        'path': deleteDir.path,
        'cover': 'file://${deleteDir.path}/cover.jpg',
        'images': {
          '': ['image-1'],
        },
        'downloadedCount': 0,
        'totalCount': 1,
        'index': 0,
        'chapter': 0,
        'completedChapters': <String>[],
        'failedChapters': <String>[],
      })!;
      manager.downloadingTasks.add(task);

      task.resume();
      await imageStarted.future.timeout(const Duration(seconds: 2));
      expect(task.debugIsRecordingSpeed, isTrue);

      task.cancel();
      expect(task.debugIsRecordingSpeed, isFalse);

      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (await deleteDir.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'active image download task cancellation did not delete its dir',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(await deleteDir.exists(), isFalse);
    },
  );

  test(
    'image download task errors when image stream ends without bytes',
    () async {
      final source = _buildSource();
      ComicSourceManager().add(source);
      await manager.init();
      managerInitialized = true;

      final downloadDir = await Directory(
        '${tempDir.path}/empty-image-download',
      ).create();
      var attempts = 0;
      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) async* {
            attempts++;
            yield ImageDownloadProgress(currentBytes: 0, totalBytes: 1);
          };
      addTearDown(ImageDownloader.debugResetReaderImageScheduling);

      final task = ImagesDownloadTask.fromJson({
        'type': 'ImagesDownloadTask',
        'source': 'test-source',
        'comicId': 'comic-empty-image-download',
        'comic': _buildDetails('comic-empty-image-download').toJson(),
        'chapters': null,
        'path': downloadDir.path,
        'cover': 'file://${downloadDir.path}/cover.jpg',
        'images': {
          '': ['image-1'],
        },
        'downloadedCount': 0,
        'totalCount': 1,
        'index': 0,
        'chapter': 0,
        'completedChapters': <String>[],
        'failedChapters': <String>[],
      })!;
      manager.downloadingTasks.add(task);

      task.resume();

      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!task.isError) {
        if (DateTime.now().isAfter(deadline)) {
          fail('image download task did not fail after empty image stream');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(task.isPaused, isTrue);
      expect(task.message, contains('no image data'));
      expect(attempts, 3);
      expect(manager.downloadingTasks, contains(task));
    },
  );

  test('init deletes malformed non-list downloading task snapshots', () async {
    await snapshotFile().writeAsString(jsonEncode({'bad': true}));

    await manager.init();
    managerInitialized = true;

    expect(await snapshotFile().exists(), isFalse);
    expect(manager.downloadingTasks, isEmpty);
  });
}

class _FakeDownloadTask extends DownloadTask {
  _FakeDownloadTask(this.fakeId);

  final String fakeId;

  @override
  String? get cover => null;

  @override
  String get id => fakeId;

  @override
  bool get isError => false;

  @override
  bool get isPaused => true;

  @override
  String get message => fakeId;

  @override
  double get progress => 0;

  @override
  int get speed => 0;

  @override
  String get title => fakeId;

  @override
  ComicType get comicType => ComicType.local;

  @override
  void cancel() {}

  @override
  LocalComic toLocalComic() {
    throw UnimplementedError();
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'FakeDownloadTask', 'id': fakeId, 'message': fakeId};
  }

  @override
  void pause() {}

  @override
  void resume() {}
}

ComicSource _buildSource() {
  return ComicSource(
    'Test Source',
    'test-source',
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    (id) async => Res(_buildDetails(id)),
    null,
    (comicId, chapterId) async => const Res(['a']),
    null,
    null,
    '',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

ComicDetails _buildDetails(String id) {
  return ComicDetails.fromJson({
    'title': 'Title',
    'subTitle': 'Author',
    'cover': 'https://example.com/cover.jpg',
    'description': 'desc',
    'tags': <String, List<String>>{
      'tag': ['a'],
    },
    'chapters': null,
    'thumbnails': null,
    'recommend': null,
    'sourceKey': 'test-source',
    'comicId': id,
    'isFavorite': false,
    'subId': null,
    'isLiked': false,
    'likesCount': 1,
    'commentCount': 2,
    'uploader': 'tester',
    'uploadTime': '2026-05-22',
    'updateTime': '2026-05-22',
    'url': 'https://example.com/comic',
    'stars': 4.5,
    'maxPage': 0,
    'comments': null,
  });
}
