import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'appdata.dart';
import 'history.dart';
import 'local_archive.dart';

dynamic _decodeLocalComicJson(dynamic value) {
  if (value is! String) {
    return value;
  }
  try {
    return jsonDecode(value);
  } catch (_) {
    return null;
  }
}

@visibleForTesting
List<String> decodeLocalComicStringList(dynamic value) {
  final decoded = _decodeLocalComicJson(value);
  if (decoded is! Iterable) {
    return <String>[];
  }
  return decoded
      .where((element) => element != null)
      .map((element) => element.toString())
      .toList();
}

@visibleForTesting
ComicChapters? decodeLocalComicChapters(dynamic value) {
  return ComicChapters.fromJsonOrNull(_decodeLocalComicJson(value));
}

int _decodeLocalComicInt(dynamic value, [int fallback = 0]) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

@visibleForTesting
DateTime decodeLocalComicCreatedAt(dynamic value) {
  return DateTime.fromMillisecondsSinceEpoch(_decodeLocalComicInt(value));
}

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  /// The name of the directory where the comic is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final ComicChapters? chapters;

  bool get hasChapters => chapters != null;

  /// relative path to the cover image
  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  const LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
  });

  LocalComic.fromRow(Row row)
    : id = row[0]?.toString() ?? '',
      title = row[1]?.toString() ?? '',
      subtitle = row[2]?.toString() ?? '',
      tags = decodeLocalComicStringList(row[3]),
      directory = row[4]?.toString() ?? '',
      chapters = decodeLocalComicChapters(row[5]),
      cover = row[6]?.toString() ?? '',
      comicType = ComicType(_decodeLocalComicInt(row[7])),
      downloadedChapters = decodeLocalComicStringList(row[8]),
      createdAt = decodeLocalComicCreatedAt(row[9]);

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  /// A lightweight availability check used by synchronous download-state
  /// queries. Full manifest and ZIP validation happens in
  /// [LocalArchiveService] before any extraction.
  bool get hasArchiveOnDisk =>
      File(
        FilePath.join(
          baseDir,
          LocalArchiveService.metadataDirectoryName,
          LocalArchiveService.archiveFileName,
        ),
      ).existsSync() &&
      File(
        FilePath.join(
          baseDir,
          LocalArchiveService.metadataDirectoryName,
          LocalArchiveService.manifestFileName,
        ),
      ).existsSync();

  /// Also detects an interrupted or corrupt metadata pair. Writers and the
  /// reader must not silently bypass one half of an archive transaction.
  bool get hasArchiveMetadataOnDisk =>
      File(
        FilePath.join(
          baseDir,
          LocalArchiveService.metadataDirectoryName,
          LocalArchiveService.archiveFileName,
        ),
      ).existsSync() ||
      File(
        FilePath.join(
          baseDir,
          LocalArchiveService.metadataDirectoryName,
          LocalArchiveService.manifestFileName,
        ),
      ).existsSync();

  @override
  String get description => "";

  @override
  String get sourceKey =>
      comicType == ComicType.local ? "local" : comicType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  Future<void> read() async {
    // Capture the exact persisted progress before doing any filesystem work.
    // Archive expansion never rewrites History, but keeping this reference
    // also protects navigation from unrelated refreshes while awaiting I/O.
    final history = HistoryManager().find(id, comicType);
    if (hasArchiveMetadataOnDisk) {
      final token = LocalArchiveCancellationToken();
      final stopwatch = Stopwatch()..start();
      var lastProgress = -1.0;
      var lastMessageElapsed = Duration.zero;
      final loadingController = showAppProgressDialog(
        App.rootContext,
        message: 'Opening compressed comic'.tl,
        onCancel: token.cancel,
      );
      try {
        await LocalArchiveService().restore(
          this,
          cancellationToken: token,
          onProgress: (progress) {
            final value = localArchiveOverallProgress(
              progress,
            ).clamp(lastProgress < 0 ? 0.0 : lastProgress, 1.0);
            final elapsed = stopwatch.elapsed;
            if (value - lastProgress < 0.005 &&
                elapsed - lastMessageElapsed <
                    const Duration(milliseconds: 500) &&
                value != 1.0) {
              return;
            }
            lastProgress = value;
            lastMessageElapsed = elapsed;
            loadingController.setProgress(value);
            final remaining = estimateLocalArchiveRemaining(
              elapsed: elapsed,
              progress: value,
            );
            final stage = localArchiveProgressStageKey(progress.operation).tl;
            final eta = remaining == null
                ? ''
                : ' · ${'Estimated remaining @time'.tlParams({'time': formatLocalArchiveRemaining(remaining)})}';
            loadingController.setMessage('$stage$eta');
          },
        );
      } on LocalArchiveCancelledException {
        return;
      } catch (error, stackTrace) {
        Log.error(
          'LocalArchive',
          'Failed to open compressed comic $sourceKey@$id: $error',
          stackTrace,
        );
        App.rootContext.showMessage(
          message: '${'Failed to open compressed comic'.tl}: $error',
        );
        return;
      } finally {
        loadingController.close();
      }
    }
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    if (downloadedChapters.isNotEmpty && chapters != null) {
      final chapters = this.chapters!;
      if (chapters.isGrouped) {
        for (int i = 0; i < chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j = 0; j < keys.length; j++) {
            var chapterId = keys[j];
            if (downloadedChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              break;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (downloadedChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    App.rootContext.to(
      () => Reader(
        type: comicType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: history?.ep ?? firstDownloadedChapter,
        initialPage: history?.page,
        initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
        history: history ?? History.fromModel(model: this, ep: 0, page: 0),
        author: subtitle,
        tags: tags,
      ),
    );
  }

  @override
  HistoryType get historyType => comicType;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  @visibleForTesting
  static void debugResetInstance() {
    _instance = null;
  }

  late Database _db;

  /// path to the directory where all the comics are stored
  late String path;

  Timer? _saveDownloadingTasksTimer;
  Completer<void>? _scheduledDownloadingTasksSave;
  Future<void> _downloadingTasksSaveChain = Future.value();
  Future<void>? _downloadingTasksFlushFuture;
  String? _downloadingTasksFlushSnapshot;
  String? _lastWrittenDownloadingTasksSnapshot;

  @visibleForTesting
  Future<void> Function()? debugBeforeDownloadingTasksSnapshotWrite;

  Directory get directory => Directory(path);

  /// Restores an app-managed archive and atomically marks it dirty before a
  /// downloader or deletion path mutates its loose files.
  Future<void> prepareComicForWrite(LocalComic comic) async {
    if (!comic.hasArchiveMetadataOnDisk) {
      return;
    }
    await LocalArchiveService().prepareForWrite(comic);
    notifyListeners();
  }

  Future<void> prepareComicForWriteById(String id, ComicType type) async {
    final comic = find(id, type);
    if (comic != null) {
      await prepareComicForWrite(comic);
    }
  }

  Future<LocalArchiveWriteLease?> beginComicWriteById(
    String id,
    ComicType type,
  ) async {
    final comic = find(id, type);
    if (comic == null) return null;
    final lease = await LocalArchiveService().beginWrite(comic);
    notifyListeners();
    return lease;
  }

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  // return error message if failed
  Future<String?> setNewPath(String newPath) async {
    var newDir = Directory(newPath);
    if (!await newDir.exists()) {
      return "Directory does not exist";
    }
    if (!await newDir.list().isEmpty) {
      return "Directory is not empty";
    }
    try {
      await copyDirectoryIsolate(directory, newDir);
      await File(
        FilePath.join(App.dataPath, 'local_path'),
      ).writeAsString(newPath);
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    }
    await directory.deleteContents(recursive: true);
    path = newPath;
    _checkNoMedia();
    return null;
  }

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation() async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
      Log.error(
        "IO",
        "Failed to create test file in local path: $e\nUsing default path instead.",
      );
      path = await findDefaultPath();
    }
  }

  Future<void> init() async {
    _db = sqlite3.open('${App.dataPath}/local.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS comics (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        downloadedChapters TEXT NOT NULL,
        created_at INTEGER,
        PRIMARY KEY (id, comic_type)
      );
    ''');
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
      if (!directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    _checkPathValidation();
    _checkNoMedia();
    if (await _restoreDownloadingTasksOnInit()) {
      notifyListeners();
    }
  }

  Future<bool> _restoreDownloadingTasksOnInit() async {
    final file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    if (!file.existsSync()) {
      return false;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) {
        file.deleteIgnoreError();
        Log.error(
          "LocalManager",
          "Failed to restore downloading tasks: invalid snapshot format",
        );
        return false;
      }
      final tasks = decoded
          .whereType<Map>()
          .cast<Map<String, dynamic>>()
          .toList();
      final shouldEnsureSources = tasks.any((task) {
        if (task['type'] != 'ImagesDownloadTask') {
          return false;
        }
        final sourceKey = task['source'];
        return sourceKey is String && ComicSource.find(sourceKey) == null;
      });
      if (shouldEnsureSources) {
        await ComicSourceManager().ensureInit();
      }
      restoreDownloadingTasks();
      return true;
    } catch (e) {
      file.deleteIgnoreError();
      Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      return false;
    }
  }

  String findValidId(ComicType type) {
    final res = _db.select(
      '''
      SELECT id FROM comics WHERE comic_type = ?
      ORDER BY CAST(id AS INTEGER) DESC
      LIMIT 1;
      ''',
      [type.value],
    );
    if (res.isEmpty) {
      return '1';
    }
    final currentMax = int.tryParse(res.first[0]?.toString() ?? '') ?? 0;
    return (currentMax + 1).toString();
  }

  Future<void> add(LocalComic comic, [String? id]) async {
    var old = find(id ?? comic.id, comic.comicType);
    var downloaded = comic.downloadedChapters.toSet().toList();
    if (old != null) {
      downloaded = {...downloaded, ...old.downloadedChapters}.toList();
    }
    _db.execute(
      'INSERT OR REPLACE INTO comics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        id ?? comic.id,
        comic.title,
        comic.subtitle,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(downloaded),
        comic.createdAt.millisecondsSinceEpoch,
      ],
    );
    notifyListeners();
  }

  Future<void> upsertPartialComic(LocalComic comic, [String? id]) {
    return add(comic, id);
  }

  void remove(String id, ComicType comicType) async {
    _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
      id,
      comicType.value,
    ]);
    notifyListeners();
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
    notifyListeners();
  }

  List<LocalComic> getComics(LocalSortType sortType) {
    var res = _db.select('''
      SELECT * FROM comics
      ORDER BY
        ${sortType.value == 'name' ? 'title' : 'created_at'}
        ${sortType.value == 'time_asc' ? 'ASC' : 'DESC'}
      ;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = _db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  @override
  void dispose() {
    _saveDownloadingTasksTimer?.cancel();
    saveCurrentDownloadingTasksInBackground(reason: 'dispose');
    super.dispose();
    _db.close();
  }

  List<LocalComic> getRecent() {
    final res = _db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  int get count {
    final res = _db.select('''
      SELECT COUNT(*) FROM comics;
    ''');
    return _decodeLocalComicInt(res.first[0]);
  }

  LocalComic? findByName(String name) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  List<LocalComic> search(String keyword) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''',
      ['%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var comic = find(id, type) ?? (throw "Comic Not Found");
    if (comic.hasArchiveMetadataOnDisk) {
      // Reading and exports share this path, so both transparently expand an
      // archived comic while retaining the ZIP and its reading identity.
      await LocalArchiveService().restore(comic);
      comic = find(id, type) ?? comic;
    }
    var directory = Directory(comic.baseDir);
    if (comic.hasChapters) {
      var cid = ep is int
          ? comic.chapters!.ids.elementAtOrNull(ep - 1)
          : (ep as String);
      if (cid == null) {
        throw "Invalid ep";
      }
      cid = getChapterDirectoryName(cid);
      directory = Directory(FilePath.join(directory.path, cid));
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        // Do not exclude comic.cover, since it may be the first page of the chapter.
        // A file with name starting with 'cover.' is not a comic page.
        if (entity.name.startsWith('cover.')) {
          continue;
        }
        //Hidden file in some file system
        if (entity.name.startsWith('.')) {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) {
      var ai = int.tryParse(a.name.split('.').first);
      var bi = int.tryParse(b.name.split('.').first);
      if (ai != null && bi != null) {
        return ai.compareTo(bi);
      }
      return a.name.compareTo(b.name);
    });
    return files.map((e) => "file://${e.path}").toList();
  }

  bool isChapterReadable(
    String id,
    ComicType type,
    Object ep, [
    ComicChapters? chapters,
  ]) {
    if (ep is! String && ep is! int) {
      return false;
    }
    var comic = find(id, type);
    if (comic == null) {
      return false;
    }
    if (comic.chapters == null) {
      return Directory(comic.baseDir).existsSync();
    }
    var chapterId = ep is int
        ? comic.chapters!.ids.elementAtOrNull(ep - 1)
        : ep as String;
    if (chapterId == null) {
      return false;
    }
    if (chapters != null && comic.chapters?.length != chapters.length) {
      add(
        LocalComic(
          id: comic.id,
          title: comic.title,
          subtitle: comic.subtitle,
          tags: comic.tags,
          directory: comic.directory,
          chapters: chapters,
          cover: comic.cover,
          comicType: comic.comicType,
          downloadedChapters: comic.downloadedChapters,
          createdAt: comic.createdAt,
        ),
      );
      comic = find(id, type) ?? comic;
    }
    if (!comic.downloadedChapters.contains(chapterId)) {
      return false;
    }
    var isReadable = _chapterDirectoryHasImages(comic, chapterId);
    if (!isReadable) {
      repairDownloadedState(id, type);
    }
    return isReadable;
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    var comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (comic.chapters?.length != chapters.length) {
        // update
        add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            tags: comic.tags,
            directory: comic.directory,
            chapters: chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
          ),
        );
      }
    }
    var chapterId = (chapters ?? comic.chapters)!.ids.elementAtOrNull(ep - 1);
    if (chapterId == null) {
      return false;
    }
    if (!comic.downloadedChapters.contains(chapterId)) {
      return false;
    }
    if (!_chapterDirectoryHasImages(comic, chapterId)) {
      repairDownloadedState(id, type);
      return false;
    }
    return true;
  }

  List<DownloadTask> downloadingTasks = [];

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    var comic = find(id, type);
    if (comic != null) {
      if (!LocalArchiveService().canManage(comic)) {
        throw const LocalArchiveException(
          'Refusing to write into a comic outside the managed local library',
        );
      }
      return Directory(comic.baseDir);
    }
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }
    var dir = findValidDirectoryName(path, name);
    return Directory(FilePath.join(path, dir)).create().then((value) => value);
  }

  void completeTask(DownloadTask task) {
    final completedComic = task.toLocalComic();
    add(completedComic);
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasksInBackground(reason: 'complete task');
    downloadingTasks.firstOrNull?.resume();
    if (appdata.settings.boolValue('autoCompressDownloads', fallback: true)) {
      // Compression uses the archive service's serialized queue. Deliberately
      // do not await it here: the next download can start immediately, and an
      // archive failure must never turn a successful download into a failure.
      unawaited(_autoCompressCompletedComic(completedComic));
    }
  }

  Future<void> _autoCompressCompletedComic(LocalComic completedComic) async {
    try {
      final comic = find(completedComic.id, completedComic.comicType);
      if (comic == null || !LocalArchiveService().canManage(comic)) {
        return;
      }
      final result = await LocalArchiveService().compress(comic);
      Log.info(
        'LocalArchive',
        'Auto-compressed ${comic.sourceKey}@${comic.id}: '
            '${result.archiveBytes} bytes, saved ${result.savedBytes} bytes',
      );
      notifyListeners();
    } catch (error, stackTrace) {
      Log.error(
        'LocalArchive',
        'Auto-compression failed for '
            '${completedComic.sourceKey}@${completedComic.id}: $error',
        stackTrace,
      );
    }
  }

  void removeTask(DownloadTask task) {
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasksInBackground(reason: 'remove task');
  }

  void moveToFirst(DownloadTask task) {
    if (downloadingTasks.isEmpty || !downloadingTasks.contains(task)) {
      return;
    }
    if (downloadingTasks.first != task) {
      var shouldResume = !downloadingTasks.first.isPaused;
      downloadingTasks.first.pause();
      downloadingTasks.remove(task);
      downloadingTasks.insert(0, task);
      notifyListeners();
      saveCurrentDownloadingTasksInBackground(reason: 'move task');
      if (shouldResume) {
        downloadingTasks.first.resume();
      }
    }
  }

  Future<void> saveCurrentDownloadingTasks() async {
    await saveCurrentDownloadingTasksNow();
  }

  void saveCurrentDownloadingTasksInBackground({String reason = 'background'}) {
    unawaited(
      saveCurrentDownloadingTasksNow().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        Log.error(
          "LocalManager",
          "Failed to save downloading task snapshot ($reason): "
              "$error\n$stackTrace",
        );
      }),
    );
  }

  void flushCurrentDownloadingTasksInBackground({
    String reason = 'background flush',
  }) {
    unawaited(
      flushCurrentDownloadingTasks().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        Log.error(
          "LocalManager",
          "Failed to flush downloading task snapshot ($reason): "
              "$error\n$stackTrace",
        );
      }),
    );
  }

  Future<void> scheduleSaveCurrentDownloadingTasks({
    Duration delay = const Duration(milliseconds: 800),
  }) {
    _saveDownloadingTasksTimer?.cancel();
    final completer = _scheduledDownloadingTasksSave ??= Completer<void>();
    _saveDownloadingTasksTimer = Timer(delay, () {
      _saveDownloadingTasksTimer = null;
      final future = _writeDownloadingTasksSnapshot();
      _resolveScheduledDownloadingTasksSave(future);
    });
    return completer.future;
  }

  Future<void> saveCurrentDownloadingTasksNow() {
    _saveDownloadingTasksTimer?.cancel();
    _saveDownloadingTasksTimer = null;
    final future = _writeDownloadingTasksSnapshot();
    _resolveScheduledDownloadingTasksSave(future);
    return future;
  }

  Future<void> flushCurrentDownloadingTasks() {
    _saveDownloadingTasksTimer?.cancel();
    _saveDownloadingTasksTimer = null;
    final snapshot = _encodeDownloadingTasksSnapshot();
    final pending = _downloadingTasksFlushFuture;
    if (pending != null) {
      if (_downloadingTasksFlushSnapshot == snapshot) {
        _resolveScheduledDownloadingTasksSave(pending);
        return pending;
      }
      final future = pending
          .catchError((_) {})
          .then((_) => _writeDownloadingTasksSnapshot(snapshot));
      _trackDownloadingTasksFlush(future, snapshot);
      _resolveScheduledDownloadingTasksSave(future);
      return future;
    }
    final future = _writeDownloadingTasksSnapshot(snapshot);
    _trackDownloadingTasksFlush(future, snapshot);
    _resolveScheduledDownloadingTasksSave(future);
    return future;
  }

  void _trackDownloadingTasksFlush(Future<void> future, String snapshot) {
    _downloadingTasksFlushFuture = future;
    _downloadingTasksFlushSnapshot = snapshot;
    unawaited(
      future.then(
        (_) {
          if (identical(_downloadingTasksFlushFuture, future)) {
            _downloadingTasksFlushFuture = null;
            _downloadingTasksFlushSnapshot = null;
          }
        },
        onError: (_) {
          if (identical(_downloadingTasksFlushFuture, future)) {
            _downloadingTasksFlushFuture = null;
            _downloadingTasksFlushSnapshot = null;
          }
        },
      ),
    );
  }

  void _resolveScheduledDownloadingTasksSave(Future<void> future) {
    final completer = _scheduledDownloadingTasksSave;
    _scheduledDownloadingTasksSave = null;
    if (completer == null || completer.isCompleted) {
      return;
    }
    future.then(
      (_) => completer.complete(),
      onError: (Object error, StackTrace stackTrace) {
        completer.completeError(error, stackTrace);
      },
    );
  }

  String _encodeDownloadingTasksSnapshot() {
    return jsonEncode(downloadingTasks.map((e) => e.toJson()).toList());
  }

  Future<void> _writeDownloadingTasksSnapshot([String? snapshot]) {
    final data = snapshot ?? _encodeDownloadingTasksSnapshot();
    _downloadingTasksSaveChain = _downloadingTasksSaveChain
        .catchError((_) {})
        .then((_) async {
          if (_lastWrittenDownloadingTasksSnapshot == data) {
            return;
          }
          await debugBeforeDownloadingTasksSnapshotWrite?.call();
          await File(
            FilePath.join(App.dataPath, 'downloading_tasks.json'),
          ).writeAsString(data);
          _lastWrittenDownloadingTasksSnapshot = data;
        });
    return _downloadingTasksSaveChain;
  }

  void restoreDownloadingTasks() {
    var file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is! List) {
          throw const FormatException(
            'Downloading task snapshot is not a list',
          );
        }
        var changed = false;
        for (var e in decoded) {
          Map<String, dynamic>? map;
          if (e is Map) {
            try {
              map = Map<String, dynamic>.from(e);
            } catch (_) {
              changed = true;
            }
          }
          if (map == null) {
            changed = true;
            continue;
          }
          DownloadTask? task;
          try {
            task = DownloadTask.fromJson(map);
          } catch (e, s) {
            changed = true;
            Log.warning(
              "LocalManager",
              "Skip invalid downloading task snapshot: $e\n$s",
            );
            continue;
          }
          if (task != null) {
            downloadingTasks.add(task);
          } else {
            changed = true;
          }
        }
        if (changed) {
          saveCurrentDownloadingTasksInBackground(reason: 'restore cleanup');
        }
      } catch (e) {
        file.deleteIgnoreError();
        Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      }
    }
  }

  void addTask(DownloadTask task) {
    downloadingTasks.add(task);
    notifyListeners();
    saveCurrentDownloadingTasksInBackground(reason: 'add task');
    downloadingTasks.first.resume();
  }

  void markChapterDownloaded(LocalComic comic, String chapterId) {
    if (comic.chapters == null ||
        !_chapterDirectoryHasImages(comic, chapterId)) {
      return;
    }
    var downloaded = {...comic.downloadedChapters, chapterId}.toList();
    add(
      LocalComic(
        id: comic.id,
        title: comic.title,
        subtitle: comic.subtitle,
        tags: comic.tags,
        directory: comic.directory,
        chapters: comic.chapters,
        cover: comic.cover,
        comicType: comic.comicType,
        downloadedChapters: downloaded,
        createdAt: comic.createdAt,
      ),
    );
  }

  LocalComic? repairDownloadedState(String id, ComicType type) {
    var comic = find(id, type);
    if (comic == null || comic.chapters == null) {
      return comic;
    }
    var validDownloaded = comic.downloadedChapters
        .where((chapterId) => _chapterDirectoryHasImages(comic, chapterId))
        .toList();
    if (validDownloaded.length == comic.downloadedChapters.length) {
      return comic;
    }
    if (validDownloaded.isEmpty) {
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        comic.id,
        comic.comicType.value,
      ]);
      notifyListeners();
      return null;
    }
    _db.execute(
      'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
      [jsonEncode(validDownloaded), comic.id, comic.comicType.value],
    );
    notifyListeners();
    return LocalComic(
      id: comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      tags: comic.tags,
      directory: comic.directory,
      chapters: comic.chapters,
      cover: comic.cover,
      comicType: comic.comicType,
      downloadedChapters: validDownloaded,
      createdAt: comic.createdAt,
    );
  }

  void repairAllDownloadedState() {
    var changed = false;
    for (var comic in getComics(LocalSortType.timeDesc)) {
      if (comic.chapters == null) {
        continue;
      }
      var validDownloaded = comic.downloadedChapters
          .where((chapterId) => _chapterDirectoryHasImages(comic, chapterId))
          .toList();
      if (validDownloaded.length == comic.downloadedChapters.length) {
        continue;
      }
      changed = true;
      if (validDownloaded.isEmpty) {
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          comic.id,
          comic.comicType.value,
        ]);
      } else {
        _db.execute(
          'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
          [jsonEncode(validDownloaded), comic.id, comic.comicType.value],
        );
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  Future<void> repairAllDownloadedStateBatched({
    int batchSize = 8,
    bool notify = true,
  }) async {
    assert(batchSize > 0);
    var changed = false;
    var processed = 0;
    for (var comic in getComics(LocalSortType.timeDesc)) {
      if (comic.chapters == null) {
        continue;
      }
      var validDownloaded = comic.downloadedChapters
          .where((chapterId) => _chapterDirectoryHasImages(comic, chapterId))
          .toList();
      if (validDownloaded.length != comic.downloadedChapters.length) {
        changed = true;
        if (validDownloaded.isEmpty) {
          _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
            comic.id,
            comic.comicType.value,
          ]);
        } else {
          _db.execute(
            'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
            [jsonEncode(validDownloaded), comic.id, comic.comicType.value],
          );
        }
      }
      processed++;
      if (processed % batchSize == 0) {
        Log.info(
          'LocalManager',
          '[perf] local repair batch complete processed=$processed',
        );
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (changed && notify) {
      notifyListeners();
    }
  }

  void deleteComic(LocalComic c, [bool removeFileOnDisk = true]) {
    if (removeFileOnDisk && LocalArchiveService().canManage(c)) {
      var dir = Directory(c.baseDir);
      dir.deleteIgnoreError(recursive: true);
    }
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      if (HistoryManager().find(c.id, c.comicType) != null) {
        HistoryManager().remove(c.id, c.comicType);
      }
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
    }
    remove(c.id, c.comicType);
    notifyListeners();
  }

  Future<void> deleteComicChapters(LocalComic c, List<String> chapters) async {
    if (chapters.isEmpty) {
      return;
    }
    var newDownloadedChapters = c.downloadedChapters
        .where((e) => !chapters.contains(e))
        .toList();
    // Record every requested target before preparing the archive, but do not
    // filter by existence yet: an archived comic intentionally has no loose
    // chapter directories until runPreparedMutation restores them.
    final shouldRemovedDirs = chapters
        .map(
          (chapter) => Directory(
            FilePath.join(c.baseDir, getChapterDirectoryName(chapter)),
          ),
        )
        .toList(growable: false);
    Future<void> deleteChapterDirectories() async {
      for (final directory in shouldRemovedDirs) {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    }

    // Expanding first prevents a partial chapter deletion from being undone
    // by a later restore of the retained ZIP. Keep the short deletion inside
    // the archive queue so compression cannot clear the dirty marker between
    // preparation and the actual filesystem mutation.
    if (c.hasArchiveMetadataOnDisk) {
      await LocalArchiveService().runPreparedMutation(
        c,
        deleteChapterDirectories,
      );
    } else {
      await deleteChapterDirectories();
    }
    // Commit downloaded-state changes only after the filesystem deletion has
    // succeeded, otherwise repair could erase progress based on a half-failed
    // operation.
    if (newDownloadedChapters.isNotEmpty) {
      _db.execute(
        'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
        [jsonEncode(newDownloadedChapters), c.id, c.comicType.value],
      );
    } else {
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        c.id,
        c.comicType.value,
      ]);
    }
    notifyListeners();
  }

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    if (comics.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <Directory>[];
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var c in comics) {
        if (removeFileOnDisk && LocalArchiveService().canManage(c)) {
          var dir = Directory(c.baseDir);
          if (dir.existsSync()) {
            shouldRemovedDirs.add(dir);
          }
        }
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          c.id,
          c.comicType.value,
        ]);
      }
      _db.execute('COMMIT;');
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      _db.execute('ROLLBACK;');
      return;
    }

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      HistoryManager().batchDeleteHistories(comicIDs);
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _deleteDirectories(shouldRemovedDirs);
    }
  }

  void batchDeleteComicsKeepFavoritesAndHistory(List<LocalComic> comics) {
    batchDeleteComics(comics, true, false);
  }

  /// Deletes the directories in a separate isolate to avoid blocking the UI thread.
  static void _deleteDirectories(List<Directory> directories) {
    Isolate.run(() async {
      await SAFTaskWorker().init();
      for (var dir in directories) {
        try {
          if (dir.existsSync()) {
            await dir.delete(recursive: true);
          }
        } catch (e) {
          continue;
        }
      }
    });
  }

  static String getChapterDirectoryName(String name) {
    var builder = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      var char = name[i];
      if (char == '/' ||
          char == '\\' ||
          char == ':' ||
          char == '*' ||
          char == '?' ||
          char == '"' ||
          char == '<' ||
          char == '>' ||
          char == '|') {
        builder.write('_');
      } else {
        builder.write(char);
      }
    }
    return builder.toString();
  }

  static bool _chapterDirectoryHasImages(LocalComic comic, String chapterId) {
    // Archived chapters are still downloaded. Treating the intentionally
    // absent loose directory as corruption would otherwise delete the comic
    // row and its reading progress during startup repair.
    if (comic.hasArchiveOnDisk) {
      return true;
    }
    var dir = Directory(
      FilePath.join(comic.baseDir, getChapterDirectoryName(chapterId)),
    );
    if (!dir.existsSync()) {
      return false;
    }
    for (var entity in dir.listSync()) {
      if (entity is! File) {
        continue;
      }
      if (entity.name.startsWith('cover.') || entity.name.startsWith('.')) {
        continue;
      }
      return true;
    }
    return false;
  }
}

enum LocalSortType {
  name("name"),
  timeAsc("time_asc"),
  timeDesc("time_desc");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return name;
  }
}
