import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/database/backup_v2_importer.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/ext.dart';
import 'package:zip_flutter/zip_flutter.dart' deferred as zip_flutter;

import 'backup_v2.dart';
import 'io.dart';

Future<void> _dataImportQueue = Future<void>.value();

Future<T> _runDataImportExclusively<T>(Future<T> Function() action) async {
  final previous = _dataImportQueue;
  final current = Completer<void>();
  _dataImportQueue = previous.then(
    (_) => current.future,
    onError: (_) => current.future,
  );
  try {
    await previous.catchError((_) {});
    return await action();
  } finally {
    if (!current.isCompleted) {
      current.complete();
    }
  }
}

@visibleForTesting
Future<T> debugRunDataImportExclusively<T>(Future<T> Function() action) {
  return _runDataImportExclusively(action);
}

@visibleForTesting
({String sourceKey, String comicId})? splitLegacyImageFavoriteId(
  Object? rawId,
) {
  if (rawId is! String) {
    return null;
  }
  final separator = rawId.indexOf('-');
  if (separator <= 0 || separator >= rawId.length - 1) {
    return null;
  }
  return (
    sourceKey: rawId.substring(0, separator),
    comicId: rawId.substring(separator + 1),
  );
}

@visibleForTesting
String? normalizePicaSourceKey(Object? rawKey) {
  if (rawKey is! String || rawKey.isEmpty) {
    return null;
  }
  return rawKey.toLowerCase() == 'htmanga' ? 'wnacg' : rawKey;
}

@visibleForTesting
String? decodePicaFolderSyncId(Object? syncData) {
  if (syncData is! String || syncData.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(syncData);
    if (decoded is! Map) {
      return null;
    }
    final folderId = decoded['folderId'];
    return folderId is String && folderId.isNotEmpty ? folderId : null;
  } catch (_) {
    return null;
  }
}

@visibleForTesting
int? normalizePicaComicType(Object? rawType) {
  final type = switch (rawType) {
    int() => rawType,
    String() => int.tryParse(rawType),
    _ => null,
  };
  return switch (type) {
    0 => 'picacg'.hashCode,
    1 => 'ehentai'.hashCode,
    2 => 'jm'.hashCode,
    3 => 'hitomi'.hashCode,
    4 => 'wnacg'.hashCode,
    5 => 'nhentai'.hashCode,
    6 => 'nhentai'.hashCode,
    int() => type,
    _ => null,
  };
}

@visibleForTesting
List<String> splitPicaTags(Object? rawTags) {
  if (rawTags is! String || rawTags.isEmpty) {
    return <String>[];
  }
  return rawTags.split(',').where((tag) => tag.isNotEmpty).toList();
}

@visibleForTesting
int normalizePicaInt(Object? value, {int fallback = 0}) {
  return switch (value) {
    int() => value,
    String() => int.tryParse(value) ?? fallback,
    _ => fallback,
  };
}

@visibleForTesting
Map<String, String> normalizePicaFavoriteFolderTables(Iterable<Object?> names) {
  final result = <String, String>{};
  for (final name in names) {
    final raw = name?.toString();
    if (raw == null || !isValidFavoriteFolderName(raw)) {
      continue;
    }
    result[raw] = normalizeImportedFavoriteFolderName(raw);
  }
  return result;
}

@visibleForTesting
Map<String, dynamic>? decodeImportedAppData(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      return null;
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  } catch (_) {
    return null;
  }
}

@visibleForTesting
List<({String archiveName, String path})> buildAppDataExportEntries(
  String dataPath, {
  required bool sync,
}) {
  final entries = [
    (archiveName: "history.db", path: FilePath.join(dataPath, "history.db")),
    (
      archiveName: "local_favorite.db",
      path: FilePath.join(dataPath, "local_favorite.db"),
    ),
    (
      archiveName: "appdata.json",
      path: FilePath.join(dataPath, sync ? "syncdata.json" : "appdata.json"),
    ),
    (archiveName: "cookie.db", path: FilePath.join(dataPath, "cookie.db")),
  ];
  return entries.where((entry) => File(entry.path).existsSync()).toList();
}

int _appDataOperationCounter = 0;

String _nextAppDataOperationId() {
  _appDataOperationCounter = (_appDataOperationCounter + 1) & 0x3fffffff;
  return '${DateTime.now().microsecondsSinceEpoch}-$_appDataOperationCounter';
}

@visibleForTesting
File buildAppDataExportFile(String cachePath, {String? operationId}) {
  final id = operationId ?? _nextAppDataOperationId();
  return File(FilePath.join(cachePath, 'appdata-export-$id.venera'));
}

File createAppDataImportCacheFile() {
  final id = _nextAppDataOperationId();
  return File(FilePath.join(App.cachePath, 'appdata-manual-import-$id'));
}

@visibleForTesting
String? normalizeDataArchiveEntryName(Object? rawName) {
  if (rawName is! String || rawName.isEmpty || rawName.contains('\u0000')) {
    return null;
  }
  final normalized = rawName.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return null;
  }
  final segments = normalized.split('/');
  if (segments.any((segment) => segment == '..' || segment == '.')) {
    return null;
  }
  final cleanSegments = segments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (cleanSegments.isEmpty) return null;
  return cleanSegments.join('/');
}

Future<void> _extractDataArchiveSafely(
  String archivePath,
  String destinationPath,
) async {
  await Isolate.run(() async {
    await zip_flutter.loadLibrary();
    final archive = zip_flutter.ZipFile.openRead(archivePath);
    final seen = <String>{};
    try {
      final entries = archive.getAllEntries();
      if (entries.length > 100000) {
        throw const FormatException('Archive contains too many entries');
      }
      for (final entry in entries) {
        final relative = normalizeDataArchiveEntryName(entry.name);
        if (relative == null) {
          throw FormatException('Unsafe archive entry: ${entry.name}');
        }
        final duplicateKey = Platform.isWindows
            ? relative.toLowerCase()
            : relative;
        if (!seen.add(duplicateKey)) {
          throw FormatException('Duplicate archive entry: ${entry.name}');
        }
        final outputPath = FilePath.join(destinationPath, relative);
        if (!isPathInsideDirectory(outputPath, destinationPath)) {
          throw FormatException(
            'Archive entry escapes destination: ${entry.name}',
          );
        }
        if (entry.isDir) {
          Directory(outputPath).createSync(recursive: true);
        } else {
          entry.writeToFile(outputPath);
        }
      }
    } finally {
      archive.close();
    }
  });
}

@visibleForTesting
Directory buildAppDataImportDirectory(
  String cachePath,
  String prefix, {
  String? operationId,
}) {
  final id = operationId ?? _nextAppDataOperationId();
  return Directory(FilePath.join(cachePath, '$prefix-$id'));
}

Future<File> exportAppData([bool sync = true]) async {
  var cacheFile = buildAppDataExportFile(App.cachePath);
  var tempFile = File('${cacheFile.path}.tmp');
  var dataPath = App.dataPath;
  var exported = false;
  if (HistoryManager().isInitialized) {
    HistoryManager().flush();
  }
  try {
    await tempFile.deleteIgnoreError();
    await cacheFile.deleteIgnoreError();
    await Isolate.run(() async {
      await zip_flutter.loadLibrary();
      var zipFile = zip_flutter.ZipFile.open(tempFile.path);
      for (final entry in buildAppDataExportEntries(dataPath, sync: sync)) {
        zipFile.addFile(entry.archiveName, entry.path);
      }
      final comicSourceDir = Directory(FilePath.join(dataPath, "comic_source"));
      if (comicSourceDir.existsSync()) {
        for (var file in comicSourceDir.listSync()) {
          if (file is File) {
            zipFile.addFile("comic_source/${file.name}", file.path);
          }
        }
      }
      final logical = buildBackupV2Payload(
        dataPath: dataPath,
        appVersion: App.version,
        useSyncAppdata: sync,
      );
      for (final entry in logical.entries.entries) {
        zipFile.addFileFromBytes(entry.key, entry.value);
      }
      zipFile.addFileFromBytes(
        backupManifestEntryName,
        Uint8List.fromList(utf8.encode(jsonEncode(logical.manifest.toJson()))),
      );
      zipFile.close();
    });
    await tempFile.rename(cacheFile.path);
    exported = true;
    return cacheFile;
  } finally {
    await tempFile.deleteIgnoreError();
    if (!exported) {
      await cacheFile.deleteIgnoreError();
    }
  }
}

Future<void> importAppData(File file, [bool checkVersion = false]) {
  return _runDataImportExclusively(
    () => _importAppDataLocked(file, checkVersion),
  );
}

Future<void> _importAppDataLocked(File file, bool checkVersion) async {
  var cacheDir = buildAppDataImportDirectory(App.cachePath, 'appdata-import');
  var cacheDirPath = cacheDir.path;
  cacheDir.createSync();
  try {
    await _extractDataArchiveSafely(file.path, cacheDirPath);
    final backupV2Manifest = validateExtractedBackupV2(cacheDir);
    var historyFile = cacheDir.joinFile("history.db");
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    var appdataFile = cacheDir.joinFile("appdata.json");
    var cookieFile = cacheDir.joinFile("cookie.db");
    if (checkVersion && appdataFile.existsSync()) {
      var data = decodeImportedAppData(await appdataFile.readAsString());
      if (data == null) {
        Log.warning("Import Data", "Skip malformed appdata.json");
        return;
      }
      final settings = data["settings"];
      final version = settings is Map ? settings["dataVersion"] : null;
      final importedVersion = switch (version) {
        int() => version < 0 ? null : version,
        String() => int.tryParse(version),
        _ => null,
      };
      if (importedVersion != null &&
          importedVersion <=
              normalizeDataVersion(appdata.settings["dataVersion"])) {
        return;
      }
    }
    if (await historyFile.exists()) {
      HistoryManager().close();
      File(FilePath.join(App.dataPath, "history.db")).deleteIfExistsSync();
      historyFile.renameSync(FilePath.join(App.dataPath, "history.db"));
      await HistoryManager().init();
      HistoryManager().updateCache();
    }
    if (await localFavoriteFile.exists()) {
      LocalFavoritesManager().close();
      File(
        FilePath.join(App.dataPath, "local_favorite.db"),
      ).deleteIfExistsSync();
      localFavoriteFile.renameSync(
        FilePath.join(App.dataPath, "local_favorite.db"),
      );
      LocalFavoritesManager().init();
    }
    if (await cookieFile.exists()) {
      SingleInstanceCookieJar.instance?.dispose();
      File(FilePath.join(App.dataPath, "cookie.db")).deleteIfExistsSync();
      cookieFile.renameSync(FilePath.join(App.dataPath, "cookie.db"));
      SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
        FilePath.join(App.dataPath, "cookie.db"),
      )..init();
    }
    var comicSourceDir = FilePath.join(cacheDirPath, "comic_source");
    if (Directory(comicSourceDir).existsSync()) {
      Directory(
        FilePath.join(App.dataPath, "comic_source"),
      ).deleteIfExistsSync(recursive: true);
      Directory(FilePath.join(App.dataPath, "comic_source")).createSync();
      for (var file in Directory(comicSourceDir).listSync()) {
        if (file is File) {
          var targetFile = FilePath.join(
            App.dataPath,
            "comic_source",
            file.name,
          );
          await file.copy(targetFile);
        }
      }
      await ComicSourceManager().reload();
    }
    if (await appdataFile.exists()) {
      var content = await appdataFile.readAsString();
      var data = decodeImportedAppData(content);
      if (data == null) {
        Log.warning("Import Data", "Skip malformed appdata.json");
      } else {
        appdata.syncData(data);
        await _sanitizeImportedSourceSettings();
      }
    }
    if (backupV2Manifest != null) {
      final rewriteDatabase = AppDatabase(
        path: FilePath.join(App.dataPath, AppDatabase.fileName),
      );
      try {
        await rewriteDatabase.initialize();
        await BackupV2Importer(rewriteDatabase).importDirectory(cacheDir);
      } finally {
        await rewriteDatabase.close();
      }
    }
  } finally {
    await cacheDir.deleteIgnoreError(recursive: true);
  }
}

Future<void> _sanitizeImportedSourceSettings() async {
  final sources = ComicSource.all();
  final sourceKeys = sources.map((e) => e.key).toSet();
  final favoriteKeys = sources
      .where((e) => e.favoriteData != null)
      .map((e) => e.key)
      .toSet();
  final searchKeys = sources
      .where((e) => e.searchPageData != null)
      .map((e) => e.key)
      .toSet();
  final categoryNames = sources
      .where((e) => e.categoryData != null)
      .map((e) => e.name)
      .toSet();
  final exploreNames = sources
      .expand((e) => e.explorePages.map((page) => page.title))
      .toSet();

  List<String> sanitize(dynamic value, Set<String> allowed) {
    if (value is! List) return <String>[];
    return value.whereType<String>().where(allowed.contains).toSet().toList();
  }

  appdata.settings['favorites'] = sanitize(
    appdata.settings['favorites'],
    favoriteKeys,
  );
  appdata.settings['searchSources'] = sanitize(
    appdata.settings['searchSources'],
    searchKeys,
  );
  appdata.settings['categories'] = sanitize(
    appdata.settings['categories'],
    categoryNames,
  );
  appdata.settings['explore_pages'] = sanitize(
    appdata.settings['explore_pages'],
    exploreNames,
  );
  if (appdata.settings['defaultSearchTarget'] is String &&
      !sourceKeys.contains(appdata.settings['defaultSearchTarget'])) {
    appdata.settings['defaultSearchTarget'] = null;
  }
  await appdata.saveData(false);
}

Future<void> importPicaData(File file) {
  return _runDataImportExclusively(() => _importPicaDataLocked(file));
}

Future<void> _importPicaDataLocked(File file) async {
  var cacheDir = buildAppDataImportDirectory(App.cachePath, 'pica-import');
  var cacheDirPath = cacheDir.path;
  cacheDir.createSync();
  try {
    await _extractDataArchiveSafely(file.path, cacheDirPath);
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    if (localFavoriteFile.existsSync()) {
      var db = sqlite3.open(localFavoriteFile.path);
      try {
        var folderNames = db
            .select("SELECT name FROM sqlite_master WHERE type='table';")
            .map((e) => e["name"])
            .toList();
        final importedFolders = normalizePicaFavoriteFolderTables(folderNames);
        for (var folderSyncValue in db.select("SELECT * FROM folder_sync;")) {
          final rawFolderName = folderSyncValue["folder_name"]?.toString();
          final folderName = importedFolders[rawFolderName];
          final sourceKey = normalizePicaSourceKey(folderSyncValue["key"]);
          final folderId = decodePicaFolderSyncId(folderSyncValue["sync_data"]);
          if (folderName == null ||
              folderName.isEmpty ||
              sourceKey == null ||
              folderId == null) {
            continue;
          }
          // 有值就跳过
          if (LocalFavoritesManager().findLinked(folderName).$1 != null) {
            continue;
          }
          LocalFavoritesManager().linkFolderToNetwork(
            folderName,
            sourceKey,
            folderId,
          );
        }
        for (var entry in importedFolders.entries) {
          final rawFolderName = entry.key;
          final folderName = entry.value;
          if (!LocalFavoritesManager().existsFolder(folderName)) {
            LocalFavoritesManager().createFolder(folderName);
          }
          for (var comic in db.select("SELECT * FROM \"$rawFolderName\";")) {
            final id = comic['target']?.toString();
            final name = comic['name']?.toString();
            final type = normalizePicaComicType(comic['type']);
            if (id == null || id.isEmpty || name == null || type == null) {
              continue;
            }
            LocalFavoritesManager().addComic(
              folderName,
              FavoriteItem(
                id: id,
                name: name,
                coverPath: comic['cover_path']?.toString() ?? '',
                author: comic['author']?.toString() ?? '',
                type: ComicType(type),
                tags: splitPicaTags(comic['tags']),
              ),
            );
          }
        }
      } catch (e) {
        Log.error("Import Data", "Failed to import local favorite: $e");
      } finally {
        db.close();
      }
    }
    var historyFile = cacheDir.joinFile("history.db");
    if (historyFile.existsSync()) {
      var db = sqlite3.open(historyFile.path);
      try {
        for (var comic in db.select("SELECT * FROM history;")) {
          final type = normalizePicaComicType(comic['type']);
          final id = comic['target']?.toString();
          if (type == null || id == null || id.isEmpty) {
            continue;
          }
          HistoryManager().addHistory(
            History.fromMap({
              "type": type,
              "id": id,
              "max_page": normalizePicaInt(comic["max_page"]),
              "ep": normalizePicaInt(comic["ep"]),
              "page": normalizePicaInt(comic["page"]),
              "time": normalizePicaInt(
                comic["time"],
                fallback: DateTime.now().millisecondsSinceEpoch,
              ),
              "title": comic["title"]?.toString() ?? "",
              "subtitle": comic["subtitle"]?.toString() ?? "",
              "cover": comic["cover"]?.toString() ?? "",
              "readEpisode": [normalizePicaInt(comic["ep"])],
            }),
          );
        }
        List<ImageFavoritesComic> imageFavoritesComicList =
            ImageFavoriteManager().comics;
        for (var comic in db.select("SELECT * FROM image_favorites;")) {
          final legacyId = splitLegacyImageFavoriteId(comic["id"]);
          if (legacyId == null) {
            Log.warning(
              "Import Data",
              "Skip invalid image favorite id: ${comic["id"]}",
            );
            continue;
          }
          String sourceKey = legacyId.sourceKey;
          // 换名字了, 绅士漫画
          if (sourceKey.toLowerCase() == "htmanga") {
            sourceKey = "wnacg";
          }
          if (ComicSource.find(sourceKey) == null) {
            continue;
          }
          String id = legacyId.comicId;
          int page = normalizePicaInt(comic["page"]);
          if (page <= 0) {
            continue;
          }
          // 章节和page是从1开始的, pica 可能有从 0 开始的, 得转一下
          int ep = normalizePicaInt(comic["ep"], fallback: 1);
          if (ep == 0) {
            ep = 1;
          }
          String title = comic["title"]?.toString() ?? "";
          String epName = "";
          ImageFavoritesComic? tempComic = imageFavoritesComicList
              .firstWhereOrNull((e) => e.id == id && e.sourceKey == sourceKey);
          ImageFavorite curImageFavorite = ImageFavorite(
            page,
            "",
            null,
            "",
            id,
            ep,
            sourceKey,
            epName,
          );
          if (tempComic == null) {
            tempComic = ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              [],
              [],
              DateTime.now(),
              "",
              {},
              "",
              1,
            );
            tempComic.imageFavoritesEp = [
              ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
            ];
            imageFavoritesComicList.add(tempComic);
          } else {
            ImageFavoritesEp? tempEp = tempComic.imageFavoritesEp
                .firstWhereOrNull((e) => e.ep == ep);
            if (tempEp == null) {
              tempComic.imageFavoritesEp.add(
                ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
              );
            } else {
              // 如果已经有这个page了, 就不添加了
              if (tempEp.imageFavorites.firstWhereOrNull(
                    (e) => e.page == page,
                  ) ==
                  null) {
                tempEp.imageFavorites.add(curImageFavorite);
              }
            }
          }
        }
        for (var temp in imageFavoritesComicList) {
          ImageFavoriteManager().addOrUpdateOrDelete(
            temp,
            temp == imageFavoritesComicList.last,
          );
        }
      } catch (e, stack) {
        Log.error("Import Data", "Failed to import history: $e", stack);
      } finally {
        db.close();
      }
    }
  } finally {
    await cacheDir.deleteIgnoreError(recursive: true);
  }
}
