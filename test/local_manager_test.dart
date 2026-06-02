import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';

import 'test_native_paths.dart';

void main() {
  late Directory tempDir;
  late LocalManager manager;
  late bool managerInitialized;

  File snapshotFile() => File('${tempDir.path}/downloading_tasks.json');

  setUpAll(() {
    open.overrideFor(OperatingSystem.windows, openTestSqlite);
  });

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

    favoritesDb.dispose();
    historyDb.dispose();
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
    (comicId, chapterId) async => const Res(['a']),
    null,
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
