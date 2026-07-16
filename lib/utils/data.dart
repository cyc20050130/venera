import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/database/backup_import_coordinator.dart';
import 'package:venera/core/database/backup_v2_importer.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
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
  final syncAppdataPath = FilePath.join(dataPath, 'syncdata.json');
  final appdataPath = sync && File(syncAppdataPath).existsSync()
      ? syncAppdataPath
      : FilePath.join(dataPath, 'appdata.json');
  final entries = [
    (archiveName: "history.db", path: FilePath.join(dataPath, "history.db")),
    (
      archiveName: "local_favorite.db",
      path: FilePath.join(dataPath, "local_favorite.db"),
    ),
    (archiveName: "appdata.json", path: appdataPath),
    (archiveName: "cookie.db", path: FilePath.join(dataPath, "cookie.db")),
    if (!sync)
      (
        archiveName: "implicitData.json",
        path: FilePath.join(dataPath, "implicitData.json"),
      ),
    if (!sync)
      (
        archiveName: "downloading_tasks.json",
        path: FilePath.join(dataPath, "downloading_tasks.json"),
      ),
    if (!sync)
      (archiveName: "local.db", path: FilePath.join(dataPath, "local.db")),
    if (!sync)
      (archiveName: "local_path", path: FilePath.join(dataPath, "local_path")),
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
  return normalizeBackupEntryPath(rawName);
}

const int _maxDataArchiveEntries = 100000;
const int _maxDataArchiveEntryBytes = 2 * 1024 * 1024 * 1024;
const int _maxDataArchiveExpandedBytes = 8 * 1024 * 1024 * 1024;

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
      if (entries.length > _maxDataArchiveEntries) {
        throw const FormatException('Archive contains too many entries');
      }
      final plannedEntries = <({int index, String relative})>[];
      var expandedBytes = 0;
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        final relative = normalizeDataArchiveEntryName(entry.name);
        if (relative == null) {
          throw FormatException('Unsafe archive entry: ${entry.name}');
        }
        // Backup files are portable across case-sensitive and
        // case-insensitive filesystems. Reject case-only duplicates before
        // extraction so they cannot overwrite one another after migration.
        final duplicateKey = relative.toLowerCase();
        if (!seen.add(duplicateKey)) {
          throw FormatException('Duplicate archive entry: ${entry.name}');
        }
        if (entry.size < 0 || entry.size > _maxDataArchiveEntryBytes) {
          throw FormatException('Archive entry is too large: ${entry.name}');
        }
        if (relative == backupManifestEntryName &&
            entry.size > maxBackupManifestBytes) {
          throw const FormatException('Backup manifest is too large');
        }
        expandedBytes += entry.size;
        if (expandedBytes > _maxDataArchiveExpandedBytes) {
          throw const FormatException('Archive expands beyond the size limit');
        }
        final outputPath = FilePath.join(destinationPath, relative);
        if (!isPathInsideDirectory(outputPath, destinationPath)) {
          throw FormatException(
            'Archive entry escapes destination: ${entry.name}',
          );
        }
        plannedEntries.add((index: index, relative: relative));
      }
      // Complete validation before writing the first byte. A malformed or
      // oversized archive therefore cannot leave a partially expanded tree.
      for (final planned in plannedEntries) {
        final entry = entries[planned.index];
        final outputPath = FilePath.join(destinationPath, planned.relative);
        if (entry.isDir) {
          Directory(outputPath).createSync(recursive: true);
        } else {
          entry.writeToFile(outputPath);
          if (File(outputPath).lengthSync() != entry.size) {
            throw FormatException(
              'Archive entry length mismatch: ${entry.name}',
            );
          }
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

Future<File> exportAppData([bool sync = true]) {
  return _exportAppData(sync: sync, flushRuntimeState: true);
}

/// Creates the mandatory rewrite backup before legacy managers are opened.
/// Persisting [appdata] here would overwrite the legacy on-disk settings with
/// constructor defaults, so this entry point snapshots disk state as-is.
Future<File> exportAppDataForRewrite() {
  return _exportAppData(sync: false, flushRuntimeState: false);
}

Future<File> _exportAppData({
  required bool sync,
  required bool flushRuntimeState,
}) async {
  var cacheFile = buildAppDataExportFile(App.cachePath);
  var tempFile = File('${cacheFile.path}.tmp');
  final snapshotDirectory = buildAppDataImportDirectory(
    App.cachePath,
    'appdata-export-snapshot',
  );
  var dataPath = App.dataPath;
  final imageFavoriteAssetsPath = FilePath.join(
    App.cachePath,
    'image_favorites',
  );
  var exported = false;
  if (flushRuntimeState) {
    await appdata.saveData(false);
    await appdata.writeImplicitData();
    if (HistoryManager().isInitialized) {
      HistoryManager().flush();
    }
  }
  String? localRoot;
  final configuredLocalPath = File(FilePath.join(dataPath, 'local_path'));
  if (await configuredLocalPath.exists()) {
    localRoot = (await configuredLocalPath.readAsString()).trim();
  }
  if (localRoot == null || localRoot.isEmpty) {
    localRoot = await LocalManager().findDefaultPath();
  }
  if (flushRuntimeState && LocalManager().isInitialized) {
    await LocalManager().flushCurrentDownloadingTasks();
  }
  if (flushRuntimeState) {
    await Future.wait(
      ComicSource.all().map((source) => source.flushPendingDataWrite()),
    );
  }
  try {
    await tempFile.deleteIgnoreError();
    await cacheFile.deleteIgnoreError();
    await Isolate.run(() async {
      await _createAppDataExportSnapshot(
        sourceDataPath: dataPath,
        snapshotPath: snapshotDirectory.path,
      );
      final logical = buildBackupV2Payload(
        dataPath: snapshotDirectory.path,
        appVersion: App.version,
        useSyncAppdata: sync,
        strict: true,
        localRoot: localRoot,
        imageFavoriteAssetsPath: imageFavoriteAssetsPath,
      );
      final compatibilityEntries = <String, Uint8List>{};
      for (final entry in buildAppDataExportEntries(
        snapshotDirectory.path,
        sync: sync,
      )) {
        compatibilityEntries[entry.archiveName] = File(
          entry.path,
        ).readAsBytesSync();
      }
      if (!sync && !compatibilityEntries.containsKey('local_path')) {
        compatibilityEntries['local_path'] = Uint8List.fromList(
          utf8.encode(localRoot!),
        );
      }
      final comicSourceDir = Directory(
        FilePath.join(snapshotDirectory.path, "comic_source"),
      );
      if (comicSourceDir.existsSync()) {
        for (final file in comicSourceDir.listSync().whereType<File>()) {
          compatibilityEntries['comic_source/${file.name}'] = file
              .readAsBytesSync();
        }
      }
      final payload = extendBackupV2Payload(
        logical,
        compatibilityEntries,
        kindForPath: (path) {
          if (path.startsWith('comic_source/')) {
            return 'compatibility_source_document';
          }
          if (path.endsWith('.db')) return 'compatibility_database';
          return 'compatibility_json';
        },
      );
      await zip_flutter.loadLibrary();
      final zipFile = zip_flutter.ZipFile.open(tempFile.path);
      try {
        for (final entry in payload.entries.entries) {
          zipFile.addFileFromBytes(entry.key, entry.value);
        }
        zipFile.addFileFromBytes(
          backupManifestEntryName,
          Uint8List.fromList(
            utf8.encode(jsonEncode(payload.manifest.toJson())),
          ),
        );
      } finally {
        zipFile.close();
      }
    });
    await tempFile.rename(cacheFile.path);
    exported = true;
    return cacheFile;
  } finally {
    await tempFile.deleteIgnoreError();
    await snapshotDirectory.deleteIgnoreError(recursive: true);
    if (!exported) {
      await cacheFile.deleteIgnoreError();
    }
  }
}

/// Extracts and validates a complete V2 backup without mutating application
/// data. Upgrade gates use this before accepting an externally saved backup.
Future<BackupManifestV2> validateBackupV2Archive(File file) async {
  final cacheDir = buildAppDataImportDirectory(
    App.cachePath,
    'appdata-validation',
  );
  final validationDatabaseFile = File(
    FilePath.join(
      App.cachePath,
      'venera-backup-validation-${_nextAppDataOperationId()}.db',
    ),
  );
  await cacheDir.create(recursive: true);
  try {
    await _extractDataArchiveSafely(file.path, cacheDir.path);
    final manifest = validateCompleteExtractedBackupV2(cacheDir);
    final rawLocalPath = File(FilePath.join(cacheDir.path, 'local_path'));
    final rebuilt = buildBackupV2Payload(
      dataPath: cacheDir.path,
      appVersion: manifest.appVersion,
      strict: true,
      localRoot: await rawLocalPath.exists()
          ? (await rawLocalPath.readAsString()).trim()
          : null,
    );
    for (final path in requiredRewriteBackupPaths) {
      if (path == '$backupLogicalDirectory/image_favorite_assets.json') {
        continue;
      }
      final actual = await File(
        FilePath.join(cacheDir.path, path),
      ).readAsBytes();
      final expected = rebuilt.entries[path];
      if (expected == null || !_bytesEqual(actual, expected)) {
        throw FormatException(
          'Logical backup does not match compatibility data: $path',
        );
      }
    }
    final database = AppDatabase(path: validationDatabaseFile.path);
    try {
      await database.initialize();
      await BackupV2Importer(database).importDirectory(cacheDir);
    } finally {
      await database.close();
    }
    return manifest;
  } finally {
    await validationDatabaseFile.deleteIgnoreError();
    await File('${validationDatabaseFile.path}-wal').deleteIgnoreError();
    await File('${validationDatabaseFile.path}-shm').deleteIgnoreError();
    await cacheDir.deleteIgnoreError(recursive: true);
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Future<void> importAppData(File file, [bool checkVersion = false]) {
  return _runDataImportExclusively(
    () => _importAppDataLocked(file, checkVersion),
  );
}

Future<void> _importAppDataLocked(File file, bool checkVersion) async {
  var cacheDir = buildAppDataImportDirectory(App.cachePath, 'appdata-import');
  var cacheDirPath = cacheDir.path;
  final rewriteStagingFile = File(
    FilePath.join(
      App.cachePath,
      'venera-import-${_nextAppDataOperationId()}.db',
    ),
  );
  File? normalizedLocalPathFile;
  Directory? stagedImageFavoriteAssets;
  cacheDir.createSync();
  try {
    await _extractDataArchiveSafely(file.path, cacheDirPath);
    final backupV2Manifest = validateExtractedBackupV2(cacheDir);
    var historyFile = cacheDir.joinFile("history.db");
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    var appdataFile = cacheDir.joinFile("appdata.json");
    var cookieFile = cacheDir.joinFile("cookie.db");
    var localDatabaseFile = cacheDir.joinFile("local.db");
    var localPathFile = cacheDir.joinFile("local_path");
    var implicitDataFile = cacheDir.joinFile("implicitData.json");
    var downloadingTasksFile = cacheDir.joinFile("downloading_tasks.json");
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
    final importedLocalRoot = await _readExistingLocalRoot(localPathFile);
    final currentLocalRoot = await _readExistingLocalRoot(
      File(FilePath.join(App.dataPath, 'local_path')),
    );
    final effectiveLocalRoot =
        importedLocalRoot ??
        currentLocalRoot ??
        (LocalManager().isInitialized && await LocalManager().directory.exists()
            ? LocalManager().path
            : null);
    normalizedLocalPathFile = importedLocalRoot == null
        ? null
        : await _writeNormalizedLocalPath(importedLocalRoot);
    if (backupV2Manifest != null) {
      await _buildImportedRewriteDatabase(
        cacheDir,
        rewriteStagingFile,
        localRoot: effectiveLocalRoot,
      );
      stagedImageFavoriteAssets = await _stageImageFavoriteAssets(
        cacheDir,
        backupV2Manifest,
      );
    }

    final comicSourceDirectory = Directory(
      FilePath.join(cacheDirPath, 'comic_source'),
    );
    final importSources = <BackupImportSource>[
      if (await historyFile.exists())
        BackupImportSource(relativePath: 'history.db', source: historyFile),
      if (await localFavoriteFile.exists())
        BackupImportSource(
          relativePath: 'local_favorite.db',
          source: localFavoriteFile,
        ),
      if (await cookieFile.exists())
        BackupImportSource(relativePath: 'cookie.db', source: cookieFile),
      if (await localDatabaseFile.exists())
        BackupImportSource(relativePath: 'local.db', source: localDatabaseFile),
      if (normalizedLocalPathFile != null)
        BackupImportSource(
          relativePath: 'local_path',
          source: normalizedLocalPathFile,
        ),
      if (await implicitDataFile.exists())
        BackupImportSource(
          relativePath: 'implicitData.json',
          source: implicitDataFile,
        ),
      if (await downloadingTasksFile.exists())
        BackupImportSource(
          relativePath: 'downloading_tasks.json',
          source: downloadingTasksFile,
        ),
      if (await comicSourceDirectory.exists())
        BackupImportSource(
          relativePath: 'comic_source',
          source: comicSourceDirectory,
        ),
    ];

    final importsHistory = importSources.any(
      (source) => source.relativePath == 'history.db',
    );
    final importsFavorites = importSources.any(
      (source) => source.relativePath == 'local_favorite.db',
    );
    final importsCookies = importSources.any(
      (source) => source.relativePath == 'cookie.db',
    );
    final importsLocalDatabase = importSources.any(
      (source) => source.relativePath == 'local.db',
    );
    final importsLocalPath = importSources.any(
      (source) => source.relativePath == 'local_path',
    );
    final importsImplicitData = importSources.any(
      (source) => source.relativePath == 'implicitData.json',
    );
    final importsDownloadingTasks = importSources.any(
      (source) => source.relativePath == 'downloading_tasks.json',
    );
    final importsSources = importSources.any(
      (source) => source.relativePath == 'comic_source',
    );

    if (importSources.isNotEmpty) {
      final coordinator = BackupImportCoordinator(
        Directory(App.dataPath),
        operationId: _nextAppDataOperationId(),
      );
      final prepared = await coordinator.prepare(importSources);
      var resumeDownloadsOnFailure = false;
      var importCommitted = false;
      var localManagerWasPrepared = false;

      if (importsHistory) HistoryManager().close();
      if (importsFavorites) LocalFavoritesManager().close();
      if (importsCookies) {
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
      }
      if ((importsLocalDatabase || importsLocalPath) &&
          LocalManager().isInitialized) {
        resumeDownloadsOnFailure = await LocalManager().prepareFullDataImport();
        localManagerWasPrepared = true;
      } else if (importsDownloadingTasks && LocalManager().isInitialized) {
        resumeDownloadsOnFailure = await LocalManager()
            .prepareDownloadingTasksImport();
      }
      try {
        await coordinator.commit(
          prepared,
          verify: () => _verifyInstalledBackupDatabases(
            importSources.map((source) => source.relativePath),
          ),
        );
        importCommitted = true;
      } finally {
        if (importsHistory) {
          await HistoryManager().init();
          HistoryManager().updateCache();
        }
        if (importsFavorites) {
          await LocalFavoritesManager().init();
        }
        if (importsCookies) {
          SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
            FilePath.join(App.dataPath, 'cookie.db'),
          );
        }
        if (importsSources) {
          await ComicSourceManager().reload();
        }
        if (importsImplicitData && importCommitted) {
          final decoded = jsonDecode(
            await File(
              FilePath.join(App.dataPath, 'implicitData.json'),
            ).readAsString(),
          );
          appdata.implicitData = normalizeImplicitData(decoded);
        }
        if (localManagerWasPrepared) {
          await LocalManager().reloadAfterFullDataImport(
            resumeFirst:
                resumeDownloadsOnFailure &&
                (!importCommitted || !importsDownloadingTasks),
          );
        } else if (importsDownloadingTasks && LocalManager().isInitialized) {
          if (importCommitted) {
            await LocalManager().reloadDownloadingTasksFromDisk();
          } else if (resumeDownloadsOnFailure) {
            LocalManager().resumeFirstDownloadingTask();
          }
        }
      }
    }
    if (stagedImageFavoriteAssets != null) {
      final imageCoordinator = BackupImportCoordinator(
        Directory(App.cachePath),
        operationId: _nextAppDataOperationId(),
      );
      final prepared = await imageCoordinator.prepare([
        BackupImportSource(
          relativePath: 'image_favorites',
          source: stagedImageFavoriteAssets,
        ),
      ]);
      await imageCoordinator.commit(
        prepared,
        verify: () =>
            _verifyInstalledImageFavoriteAssets(stagedImageFavoriteAssets!),
      );
    }
    if (backupV2Manifest != null) {
      // The rewrite database is already kept open by its Riverpod provider.
      // Import through a second SQLite connection and one write transaction
      // instead of replacing the live file (which is not portable on Windows).
      // The staging database above validates migrations and the full projection
      // before any authoritative legacy file is committed.
      final rewriteDatabase = AppDatabase(
        path: FilePath.join(App.dataPath, AppDatabase.fileName),
      );
      try {
        await rewriteDatabase.initialize();
        await BackupV2Importer(
          rewriteDatabase,
        ).importDirectory(cacheDir, localRoot: effectiveLocalRoot);
      } finally {
        await rewriteDatabase.close();
      }
    }
    if (await appdataFile.exists()) {
      var content = await appdataFile.readAsString();
      var data = decodeImportedAppData(content);
      if (data == null) {
        Log.warning("Import Data", "Skip malformed appdata.json");
      } else {
        if (backupV2Manifest?.isFullBackup ?? false) {
          await appdata.restoreFullData(data);
        } else {
          appdata.syncData(data);
        }
        await _sanitizeImportedSourceSettings();
      }
    }
  } finally {
    await rewriteStagingFile.deleteIgnoreError();
    await File('${rewriteStagingFile.path}-wal').deleteIgnoreError();
    await File('${rewriteStagingFile.path}-shm').deleteIgnoreError();
    await normalizedLocalPathFile?.deleteIgnoreError();
    await stagedImageFavoriteAssets?.deleteIgnoreError(recursive: true);
    await cacheDir.deleteIgnoreError(recursive: true);
  }
}

Future<void> _createAppDataExportSnapshot({
  required String sourceDataPath,
  required String snapshotPath,
}) async {
  final snapshotDirectory = Directory(snapshotPath);
  await snapshotDirectory.deleteIfExists(recursive: true);
  await snapshotDirectory.create(recursive: true);

  const databaseNames = [
    'history.db',
    'local_favorite.db',
    'cookie.db',
    'local.db',
  ];
  for (final name in databaseNames) {
    final source = File(FilePath.join(sourceDataPath, name));
    if (!await source.exists()) continue;
    final destination = File(FilePath.join(snapshotPath, name));
    try {
      final sourceDatabase = sqlite3.open(source.path, mode: OpenMode.readOnly);
      final destinationDatabase = sqlite3.open(destination.path);
      try {
        await sourceDatabase.backup(destinationDatabase, nPage: -1).drain();
      } finally {
        destinationDatabase.close();
        sourceDatabase.close();
      }
    } catch (_) {
      // Preserve malformed legacy databases byte-for-byte. Logical V2 parsing
      // remains defensive and the compatibility importer may still understand
      // a database produced by an older application version.
      await destination.deleteIgnoreError();
      await source.copy(destination.path);
    }
  }

  for (final name in [
    'appdata.json',
    'syncdata.json',
    'local_path',
    'implicitData.json',
    'downloading_tasks.json',
  ]) {
    final source = File(FilePath.join(sourceDataPath, name));
    if (await source.exists()) {
      await source.copy(FilePath.join(snapshotPath, name));
    }
  }

  final sourceDocuments = Directory(
    FilePath.join(sourceDataPath, 'comic_source'),
  );
  if (await sourceDocuments.exists()) {
    final snapshotDocuments = Directory(
      FilePath.join(snapshotPath, 'comic_source'),
    );
    await snapshotDocuments.create(recursive: true);
    await for (final entity in sourceDocuments.list(followLinks: false)) {
      if (entity is File) {
        await entity.copy(FilePath.join(snapshotDocuments.path, entity.name));
      }
    }
  }
}

Future<String?> _readExistingLocalRoot(File file) async {
  if (!await file.exists()) return null;
  try {
    final path = (await file.readAsString()).trim();
    final directory = Directory(path);
    if (path.isEmpty || !p.isAbsolute(path) || !await directory.exists()) {
      return null;
    }
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.name;
      if (name != '.nomedia' && name != 'venera_test') return path;
    }
    return null;
  } catch (_) {
    return null;
  }
}

Future<File> _writeNormalizedLocalPath(String path) async {
  final file = File(
    FilePath.join(
      App.cachePath,
      'venera-import-local-path-${_nextAppDataOperationId()}',
    ),
  );
  await file.writeAsString(path, flush: true);
  return file;
}

Future<Directory?> _stageImageFavoriteAssets(
  Directory extractedDirectory,
  BackupManifestV2 manifest,
) async {
  const indexPath = '$backupLogicalDirectory/image_favorite_assets.json';
  if (!manifest.entries.any((entry) => entry.path == indexPath)) return null;

  final decoded = jsonDecode(
    await File(
      FilePath.join(extractedDirectory.path, indexPath),
    ).readAsString(),
  );
  if (decoded is! List) {
    throw const FormatException(
      'logical/image_favorite_assets.json must be an array',
    );
  }

  final staged = Directory(
    FilePath.join(
      App.cachePath,
      'venera-import-image-favorites-${_nextAppDataOperationId()}',
    ),
  );
  await staged.deleteIgnoreError(recursive: true);
  await staged.create(recursive: true);
  final names = <String>{};
  for (var index = 0; index < decoded.length; index++) {
    final raw = decoded[index];
    if (raw is! Map) {
      throw FormatException('Invalid image favorite asset[$index]');
    }
    final name = raw['name'];
    final sourcePath = raw['path'];
    if (name is! String ||
        normalizeBackupEntryPath(name) != name ||
        name.contains('/') ||
        !names.add(name.toLowerCase()) ||
        sourcePath is! String) {
      throw FormatException('Invalid image favorite asset[$index]');
    }
    final source = File(FilePath.join(extractedDirectory.path, sourcePath));
    if (!isPathInsideDirectory(source.path, extractedDirectory.path) ||
        !await source.exists()) {
      throw FormatException('Missing image favorite asset: $name');
    }
    await source.copy(FilePath.join(staged.path, name));
  }
  return staged;
}

Future<void> _verifyInstalledImageFavoriteAssets(Directory staged) async {
  final installed = Directory(FilePath.join(App.cachePath, 'image_favorites'));
  if (!await installed.exists()) {
    throw const FormatException('Imported image favorite assets are missing');
  }
  final expectedFiles = await staged
      .list(followLinks: false)
      .where((entity) => entity is File)
      .cast<File>()
      .toList();
  final installedEntities = await installed.list(followLinks: false).toList();
  if (installedEntities.length != expectedFiles.length ||
      installedEntities.any((entity) => entity is! File)) {
    throw const FormatException('Imported image favorite assets mismatch');
  }
  for (final expected in expectedFiles) {
    final actual = File(FilePath.join(installed.path, expected.name));
    if (!await actual.exists() ||
        await expected.length() != await actual.length() ||
        await _fileDigest(expected) != await _fileDigest(actual)) {
      throw FormatException(
        'Imported image favorite asset mismatch: ${expected.name}',
      );
    }
  }
}

Future<Digest> _fileDigest(File file) => sha256.bind(file.openRead()).first;

Future<void> _buildImportedRewriteDatabase(
  Directory extractedDirectory,
  File stagingFile, {
  String? localRoot,
}) async {
  await stagingFile.deleteIgnoreError();
  final currentFile = File(FilePath.join(App.dataPath, AppDatabase.fileName));
  Future<void> snapshotCurrentDatabase() async {
    if (!await currentFile.exists()) {
      return;
    }
    // Copying only the main SQLite file can omit committed WAL pages while the
    // rewrite database is open. SQLite backup produces a consistent snapshot
    // without replacing or closing the live Windows connection.
    final sourceDatabase = sqlite3.open(
      currentFile.path,
      mode: OpenMode.readOnly,
    );
    final stagingDatabase = sqlite3.open(stagingFile.path);
    try {
      await sourceDatabase.backup(stagingDatabase, nPage: -1).drain();
    } finally {
      stagingDatabase.close();
      sourceDatabase.close();
    }
  }

  Future<void> importIntoStaging() async {
    final rewriteDatabase = AppDatabase(path: stagingFile.path);
    try {
      await rewriteDatabase.initialize();
      await BackupV2Importer(
        rewriteDatabase,
      ).importDirectory(extractedDirectory, localRoot: localRoot);
    } finally {
      await rewriteDatabase.close();
    }
  }

  try {
    await snapshotCurrentDatabase();
    await importIntoStaging();
  } catch (error, stackTrace) {
    if (!await currentFile.exists()) {
      Error.throwWithStackTrace(error, stackTrace);
    }
    Log.warning(
      'Import Data',
      'Existing rewrite database could not be reused; rebuilding it: $error',
    );
    await stagingFile.deleteIgnoreError();
    await File('${stagingFile.path}-wal').deleteIgnoreError();
    await File('${stagingFile.path}-shm').deleteIgnoreError();
    await importIntoStaging();
  }
}

Future<void> _verifyInstalledBackupDatabases(
  Iterable<String> relativePaths,
) async {
  const databaseNames = {
    'history.db',
    'local_favorite.db',
    'cookie.db',
    'local.db',
  };
  for (final relativePath in relativePaths.where(databaseNames.contains)) {
    final path = FilePath.join(App.dataPath, relativePath);
    final database = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final result = database.select('PRAGMA quick_check;');
      if (result.isEmpty || result.first.values.first != 'ok') {
        throw FormatException(
          'Imported database failed validation: $relativePath',
        );
      }
    } finally {
      database.close();
    }
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
