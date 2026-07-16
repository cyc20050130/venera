import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:uuid/uuid.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      case "ArchiveDownloadTask":
        return ArchiveDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

String? _downloadNullableString(dynamic value) {
  if (value == null) {
    return null;
  }
  return value.toString();
}

int _downloadInt(dynamic value, [int fallback = 0]) {
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

int _downloadNonNegativeInt(dynamic value, [int fallback = 0]) {
  final parsed = _downloadInt(value, fallback);
  return parsed < 0 ? fallback : parsed;
}

Map<String, dynamic>? _downloadMap(dynamic value) {
  if (value is! Map) {
    return null;
  }
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key == null) {
      continue;
    }
    result[key.toString()] = entry.value;
  }
  return result;
}

List<String>? _downloadStringListOrNull(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is! Iterable) {
    return null;
  }
  return value
      .where((element) => element != null)
      .map((element) => element.toString())
      .toList();
}

Map<String, List<String>>? _downloadImageMap(dynamic value) {
  final map = _downloadMap(value);
  if (map == null) {
    return null;
  }
  final result = <String, List<String>>{};
  for (final entry in map.entries) {
    final images = _downloadStringListOrNull(entry.value);
    if (images == null) {
      continue;
    }
    result[entry.key] = images;
  }
  return result;
}

bool _isRestoredDownloadPositionValid(
  Map<String, List<String>>? images,
  int chapter,
  int index,
) {
  if (images == null) {
    return true;
  }
  if (chapter > images.length) {
    return false;
  }
  if (chapter == images.length) {
    return index == 0;
  }
  return index <= images.values.elementAt(chapter).length;
}

@visibleForTesting
String buildArchiveDownloadFilePath(String dataPath, String operationId) {
  return FilePath.join(dataPath, 'archive_downloading-$operationId.zip');
}

@visibleForTesting
String buildArchiveExtractCacheDirectory(String cachePath, String operationId) {
  return FilePath.join(cachePath, 'archive_downloading-$operationId');
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
  });

  @override
  void cancel() {
    _isRunning = false;
    stopRecorder();
    LocalManager().removeTask(this);
    var local = LocalManager().find(id, comicType);
    if (path != null) {
      if (local == null) {
        Future.sync(() async {
          var tasks = this.tasks.values.toList();
          for (var i = 0; i < tasks.length; i++) {
            if (!tasks[i].isComplete) {
              tasks[i].cancel();
              await tasks[i].wait();
            }
          }
          try {
            await Directory(path!).delete(recursive: true);
          } catch (e) {
            Log.error("Download", "Failed to delete directory: $e");
          }
        });
      } else if (chapters != null) {
        for (var c in chapters!) {
          var dir = Directory(
            FilePath.join(path!, LocalManager.getChapterDirectoryName(c)),
          );
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        }
      }
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _message = "Paused";
    _currentSpeed = 0;
    var shouldMove = <int>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    stopRecorder();
    notifyListeners();
    LocalManager().saveCurrentDownloadingTasksInBackground(
      reason: 'pause images task',
    );
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...";

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  final List<String> _completedChapters = [];

  final List<String> _failedChapters = [];

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  var tasks = <int, _ImageDownloadWrapper>{};

  int get _maxConcurrentTasks =>
      appdata.settings.intValue("downloadThreads", fallback: 5, min: 1);

  void _scheduleTasks() {
    var images = _images![_images!.keys.elementAt(_chapter)]!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      Directory saveTo;
      if (comic!.chapters != null) {
        saveTo = Directory(
          FilePath.join(
            path!,
            LocalManager.getChapterDirectoryName(
              _images!.keys.elementAt(_chapter),
            ),
          ),
        );
        if (!saveTo.existsSync()) {
          saveTo.createSync(recursive: true);
        }
      } else {
        saveTo = Directory(path!);
      }
      var task = _ImageDownloadWrapper(
        this,
        _images!.keys.elementAt(_chapter),
        images[i],
        saveTo,
        i,
      );
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete) {
          _scheduleTasks();
        }
      });
      downloading++;
    }
  }

  @override
  void resume() async {
    try {
      if (_isRunning) return;
      _isError = false;
      _message = "Resuming...";
      _isRunning = true;
      notifyListeners();
      runRecorder();

      if (comic == null) {
        _message = "Fetching comic info...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicInfo!(comicId);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) {
          return;
        }
        if (res.error) {
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          comic = res.data;
        }
      }

      if (path == null) {
        try {
          var dir = await LocalManager().findValidDirectory(
            comicId,
            comicType,
            comic!.title,
          );
          if (!(await dir.exists())) {
            await dir.create();
          }
          path = dir.path;
        } catch (e, s) {
          Log.error("Download", e.toString(), s);
          _setError("Error: $e");
          return;
        }
      }

      await LocalManager().saveCurrentDownloadingTasksNow();

      if (_cover == null) {
        _message = "Downloading cover...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          Uint8List? data;
          await for (var progress in ImageDownloader.loadThumbnail(
            comic!.cover,
            source.key,
            comicId,
            ThumbnailLoadPriority.background,
            () {
              if (!_isRunning) {
                throw "Download cancelled";
              }
            },
          )) {
            if (progress.imageBytes != null) {
              data = progress.imageBytes;
            }
          }
          if (data == null) {
            throw "Failed to download cover";
          }
          var fileType = detectFileType(data);
          var file = File(FilePath.join(path!, "cover${fileType.ext}"));
          file.writeAsBytesSync(data);
          return "file://${file.path}";
        });
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _cover = res.data;
          notifyListeners();
        }
        await LocalManager().upsertPartialComic(
          _buildLocalComic(_completedChapters),
        );
        await LocalManager().saveCurrentDownloadingTasksNow();
      }

      if (_images == null) {
        if (comic!.chapters == null) {
          _message = "Fetching image list...";
          notifyListeners();
          var res = await _runWithRetry(() async {
            var r = await source.loadComicPages!(comicId, null);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
          if (!_isRunning) {
            return;
          }
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          } else {
            _images = {'': res.data};
            _totalCount = _images!['']!.length;
          }
        } else {
          _images = {};
          _totalCount = 0;
          int cpCount = 0;
          int totalCpCount =
              chapters?.length ?? comic!.chapters!.allChapters.length;
          for (var i in comic!.chapters!.allChapters.keys) {
            if (chapters != null && !chapters!.contains(i)) {
              continue;
            }
            if (_images![i] != null) {
              _totalCount += _images![i]!.length;
              continue;
            }
            _message = "Fetching image list ($cpCount/$totalCpCount)...";
            notifyListeners();
            var res = await _runWithRetry(() async {
              var r = await source.loadComicPages!(comicId, i);
              if (r.error) {
                throw r.errorMessage!;
              } else {
                return r.data;
              }
            });
            if (!_isRunning) {
              return;
            }
            if (res.error) {
              Log.error("Download", res.errorMessage!);
              _failedChapters.add(i);
              cpCount++;
              continue;
            } else {
              _images![i] = res.data;
              _totalCount += _images![i]!.length;
              cpCount++;
            }
          }
        }
        _message = "$_downloadedCount/$_totalCount";
        notifyListeners();
        await LocalManager().saveCurrentDownloadingTasksNow();
      }

      final writeLease = _chapter < _images!.length
          ? await LocalManager().beginComicWriteById(id, comicType)
          : null;
      if (_chapter < _images!.length) {
        // Restore only when page writes are actually about to begin. This
        // avoids doubling storage while a resumed task is still fetching
        // metadata or waiting on the network. The lease also keeps a manual
        // compression from snapshotting only part of the active download.
        if (!_isRunning) {
          writeLease?.close();
          return;
        }
      }

      try {
        while (_chapter < _images!.length) {
          var images = _images![_images!.keys.elementAt(_chapter)]!;
          tasks.clear();
          var chapterFailed = false;
          while (_index < images.length) {
            _scheduleTasks();
            var task = tasks[_index]!;
            await task.wait();
            if (isPaused) {
              return;
            }
            if (task.error != null) {
              Log.error("Download", task.error.toString());
              if (comic?.chapters == null) {
                _setError("Error: ${task.error}");
                return;
              }
              await _markCurrentChapterFailed();
              chapterFailed = true;
              break;
            }
            _index++;
            _downloadedCount++;
            _message = "$_downloadedCount/$_totalCount";
            await LocalManager().scheduleSaveCurrentDownloadingTasks();
          }
          _index = 0;
          if (!chapterFailed) {
            _markCurrentChapterDownloaded();
          }
          _chapter++;
        }
      } finally {
        writeLease?.close();
      }

      if (_failedChapters.isNotEmpty) {
        Log.warning(
          "Download",
          "Skipped chapters for $comicId: ${_failedChapters.join(', ')}",
        );
      }
      LocalManager().completeTask(this);
      stopRecorder();
    } catch (e, s) {
      Log.error("Download", "Unhandled images download task failure: $e", s);
      _setError("Error: $e");
      LocalManager().saveCurrentDownloadingTasksInBackground(
        reason: 'images task failure',
      );
    }
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
    LocalManager().saveCurrentDownloadingTasksInBackground(
      reason: 'images task error',
    );
  }

  @override
  int get speed => currentSpeed;

  @visibleForTesting
  bool get debugIsRecordingSpeed => isRecordingSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
      "completedChapters": _completedChapters,
      "failedChapters": _failedChapters,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    final sourceKey = _downloadNullableString(json["source"]);
    final source = sourceKey == null ? null : ComicSource.find(sourceKey);
    final comicId = _downloadNullableString(json["comicId"]);
    if (source == null || comicId == null || comicId.isEmpty) {
      return null;
    }

    final comicJson = _downloadMap(json["comic"]);

    final images = _downloadImageMap(json["images"]);
    final index = _downloadNonNegativeInt(json["index"]);
    final chapter = _downloadNonNegativeInt(json["chapter"]);
    if (!_isRestoredDownloadPositionValid(images, chapter, index)) {
      return null;
    }

    return ImagesDownloadTask(
        source: source,
        comicId: comicId,
        comic: comicJson == null ? null : ComicDetails.fromJson(comicJson),
        chapters: _downloadStringListOrNull(json["chapters"]),
      )
      ..path = _downloadNullableString(json["path"])
      .._cover = _downloadNullableString(json["cover"])
      .._images = images
      .._downloadedCount = _downloadNonNegativeInt(json["downloadedCount"])
      .._totalCount = _downloadNonNegativeInt(json["totalCount"])
      .._index = index
      .._chapter = chapter
      .._completedChapters.addAll(
        _downloadStringListOrNull(json["completedChapters"]) ?? [],
      )
      .._failedChapters.addAll(
        _downloadStringListOrNull(json["failedChapters"]) ?? [],
      );
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    return _buildLocalComic(_completedChapters);
  }

  LocalComic _buildLocalComic(List<String> downloadedChapters) {
    var old = LocalManager().find(id, comicType);
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(localFilePathFromUri(_cover!)).name,
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: downloadedChapters,
      createdAt: old?.createdAt ?? DateTime.now(),
    );
  }

  void _markCurrentChapterDownloaded() {
    if (comic?.chapters == null || _images == null || path == null) {
      return;
    }
    var chapterId = _images!.keys.elementAtOrNull(_chapter);
    if (chapterId == null) {
      return;
    }
    if (!_completedChapters.contains(chapterId)) {
      _completedChapters.add(chapterId);
    }
    var comicModel = _buildLocalComic(const []);
    LocalManager().markChapterDownloaded(comicModel, chapterId);
  }

  Future<void> _markCurrentChapterFailed() async {
    if (comic?.chapters == null || _images == null || path == null) {
      return;
    }
    var chapterId = _images!.keys.elementAtOrNull(_chapter);
    if (chapterId == null) {
      return;
    }
    if (!_failedChapters.contains(chapterId)) {
      _failedChapters.add(chapterId);
    }
    var dir = Directory(
      FilePath.join(path!, LocalManager.getChapterDirectoryName(chapterId)),
    );
    await dir.deleteIgnoreError(recursive: true);
    _message = "Skipped ${comic!.chapters![chapterId] ?? chapterId}";
    notifyListeners();
    await LocalManager().saveCurrentDownloadingTasksNow();
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

Future<Res<T>> _runWithRetry<T>(
  Future<T> Function() task, {
  int retry = 3,
}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
    _completeWaiters();
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  void _completeWaiters() {
    for (var c in completers) {
      if (!c.isCompleted) {
        c.complete(this);
      }
    }
    completers.clear();
  }

  void start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadComicImageNoCache(
        image,
        task.source.key,
        task.comicId,
        chapter,
      )) {
        if (isCancelled) {
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          if (p.imageBytes!.isEmpty) {
            throw "Failed to download image: empty image data";
          }
          var fileType = detectFileType(p.imageBytes!);
          var file = saveTo.joinFile("$index${fileType.ext}");
          await file.writeAsBytes(p.imageBytes!);
          isComplete = true;
          _completeWaiters();
        }
      }
      if (!isComplete && !isCancelled) {
        throw "Failed to download image: no image data";
      }
    } catch (e, s) {
      if (isCancelled) {
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        start();
        return;
      }
      error = e.toString();
      _completeWaiters();
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete || isCancelled || error != null) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  bool get isRecordingSpeed => timer?.isActive ?? false;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  final ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  factory ArchiveDownloadTask(String archiveUrl, ComicDetails comic) {
    final task = ArchiveDownloadTask.tryCreate(archiveUrl, comic);
    if (task == null) {
      throw StateError('Comic source not found: ${comic.sourceKey}');
    }
    return task;
  }

  ArchiveDownloadTask._(this.archiveUrl, this.comic, this.source);

  static ArchiveDownloadTask? tryCreate(String archiveUrl, ComicDetails comic) {
    if (archiveUrl.isEmpty) {
      return null;
    }
    final source = ComicSource.find(comic.sourceKey);
    if (source == null) {
      return null;
    }
    return ArchiveDownloadTask._(archiveUrl, comic, source);
  }

  FileDownloader? _downloader;
  Future<void>? _activeExtraction;

  String _message = "Fetching comic info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
    LocalManager().saveCurrentDownloadingTasksInBackground(
      reason: 'archive task error',
    );
  }

  @override
  void cancel() async {
    _isRunning = false;
    await _downloader?.stop();
    final extraction = _activeExtraction;
    if (extraction != null) {
      try {
        await extraction;
      } catch (_) {
        // The resume path owns extraction error reporting.
      }
    }
    final existing = LocalManager().find(id, comicType);
    if (path != null && existing == null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    _message = "Paused";
    _downloader?.stop();
    notifyListeners();
    LocalManager().saveCurrentDownloadingTasksInBackground(
      reason: 'pause archive task',
    );
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() async {
    try {
      if (_isRunning) {
        return;
      }
      _isError = false;
      _isRunning = true;
      notifyListeners();
      _message = "Downloading...";

      if (path == null) {
        var dir = await LocalManager().findValidDirectory(
          comic.id,
          comicType,
          comic.title,
        );
        if (!(await dir.exists())) {
          try {
            await dir.create();
          } catch (e) {
            _setError("Error: $e");
            return;
          }
        }
        path = dir.path;
      }

      final operationId = const Uuid().v4();
      final archiveFile = File(
        buildArchiveDownloadFilePath(App.dataPath, operationId),
      );
      try {
        Log.info("Download", "Downloading $archiveUrl");

        _downloader = FileDownloader(archiveUrl, archiveFile.path);

        bool isDownloaded = false;

        try {
          await for (var status in _downloader!.start()) {
            _currentBytes = status.downloadedBytes;
            _expectedBytes = status.totalBytes;
            _message =
                "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
            _speed = status.bytesPerSecond;
            isDownloaded = status.isFinished;
            notifyListeners();
          }
        } catch (e) {
          _setError("Error: $e");
          return;
        }

        if (!_isRunning) {
          return;
        }

        if (!isDownloaded) {
          _setError("Error: Download failed");
          return;
        }

        try {
          // Preserve the old archive and mark its expanded tree dirty only
          // after the replacement archive is fully downloaded and immediately
          // before files are extracted into the comic directory.
          final writeLease = await LocalManager().beginComicWriteById(
            id,
            comicType,
          );
          if (!_isRunning) {
            writeLease?.close();
            return;
          }
          try {
            final extraction = _extractArchive(
              archiveFile.path,
              path!,
              operationId: operationId,
            );
            _activeExtraction = extraction;
            await extraction;
          } finally {
            _activeExtraction = null;
            writeLease?.close();
          }
        } catch (e) {
          _setError("Failed to extract archive: $e");
          return;
        }

        if (!_isRunning) {
          return;
        }
        LocalManager().completeTask(this);
      } finally {
        await archiveFile.deleteIgnoreError();
      }
    } catch (e, s) {
      Log.error("Download", "Unhandled archive download task failure: $e", s);
      _setError("Error: $e");
    }
  }

  static Future<void> _extractArchive(
    String archive,
    String outDir, {
    String? operationId,
  }) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = buildArchiveExtractCacheDirectory(
        App.cachePath,
        operationId ?? const Uuid().v4(),
      );
      Directory(cacheDir).forceCreateSync();
      try {
        await Isolate.run(() {
          ZipFile.openAndExtract(archive, cacheDir);
        });
        await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      } finally {
        await Directory(cacheDir).deleteIgnoreError(recursive: true);
      }
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    final archiveUrl = _downloadNullableString(json["archiveUrl"]);
    final comicJson = _downloadMap(json["comic"]);
    if (archiveUrl == null || archiveUrl.isEmpty || comicJson == null) {
      return null;
    }
    final comic = ComicDetails.fromJson(comicJson);
    if (comic.id.isEmpty || ComicSource.find(comic.sourceKey) == null) {
      return null;
    }
    return ArchiveDownloadTask.tryCreate(archiveUrl, comic)
      ?..path = _downloadNullableString(json["path"]);
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    if (files.isEmpty) {
      throw StateError('Archive download produced no files');
    }
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
