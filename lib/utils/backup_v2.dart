import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'io.dart';

const int currentBackupFormatVersion = 2;
const String backupManifestEntryName = 'manifest.json';
const String backupLogicalDirectory = 'logical';
const int maxBackupManifestBytes = 32 * 1024 * 1024;
const Set<String> requiredRewriteBackupPaths = {
  '$backupLogicalDirectory/appdata.json',
  '$backupLogicalDirectory/implicit_data.json',
  '$backupLogicalDirectory/history.json',
  '$backupLogicalDirectory/image_favorites.json',
  '$backupLogicalDirectory/favorites.json',
  '$backupLogicalDirectory/cookies.json',
  '$backupLogicalDirectory/download_tasks.json',
  '$backupLogicalDirectory/local_index.json',
  '$backupLogicalDirectory/sources.json',
  '$backupLogicalDirectory/image_favorite_assets.json',
};

/// Returns one portable, traversal-free path for a backup entry.
///
/// Backups move between case-sensitive POSIX filesystems and Windows. Reject
/// Windows aliases on every platform so an entry that is harmless on the
/// exporting device cannot overwrite another entry through an NTFS alternate
/// stream, a reserved device name, or trailing-dot/space normalization.
String? normalizeBackupEntryPath(Object? rawPath) {
  if (rawPath is! String || rawPath.isEmpty || rawPath.contains('\u0000')) {
    return null;
  }
  final normalized = rawPath.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return null;
  }
  final segments = normalized.split('/');
  final cleanSegments = <String>[];
  const reservedWindowsNames = {
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'com2',
    'com3',
    'com4',
    'com5',
    'com6',
    'com7',
    'com8',
    'com9',
    'lpt1',
    'lpt2',
    'lpt3',
    'lpt4',
    'lpt5',
    'lpt6',
    'lpt7',
    'lpt8',
    'lpt9',
  };
  for (final segment in segments) {
    if (segment.isEmpty) continue;
    if (segment == '.' ||
        segment == '..' ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(segment)) {
      return null;
    }
    final deviceName = segment.split('.').first.toLowerCase();
    if (reservedWindowsNames.contains(deviceName)) return null;
    cleanSegments.add(segment);
  }
  if (cleanSegments.isEmpty) return null;
  return cleanSegments.join('/');
}

final class BackupManifestV2 {
  const BackupManifestV2({
    required this.createdAt,
    required this.appVersion,
    required this.isFullBackup,
    required this.entries,
    this.hasExplicitScope = true,
  });

  final DateTime createdAt;
  final String appVersion;
  final bool isFullBackup;
  final List<BackupEntryV2> entries;

  /// False only for Backup V2 files produced before `scope` and authenticated
  /// compatibility entries were introduced. Those files remain importable,
  /// while newly produced files use a closed manifest.
  final bool hasExplicitScope;

  /// Stable digest used to prove that the externally saved backup checked
  /// immediately before reset is the same snapshot that was first verified.
  String get fingerprint =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();

  bool get isCompleteRewriteBackup {
    if (!isFullBackup) return false;
    final paths = entries.map((entry) => entry.path).toSet();
    return paths.containsAll(requiredRewriteBackupPaths);
  }

  Map<String, Object?> toJson() => {
    'format': 'venera-backup',
    'version': currentBackupFormatVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'appVersion': appVersion,
    'scope': isFullBackup ? 'full' : 'sync',
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };

  static BackupManifestV2? tryParse(Object? value) {
    if (value is! Map ||
        value['format'] != 'venera-backup' ||
        value['version'] != currentBackupFormatVersion) {
      return null;
    }
    final createdAt = DateTime.tryParse(value['createdAt']?.toString() ?? '');
    final rawEntries = value['entries'];
    final hasExplicitScope = value.containsKey('scope');
    final scope = value['scope'];
    if (createdAt == null ||
        rawEntries is! Iterable ||
        (hasExplicitScope && scope != 'full' && scope != 'sync')) {
      return null;
    }
    final entries = rawEntries
        .map(BackupEntryV2.tryParse)
        .whereType<BackupEntryV2>()
        .toList(growable: false);
    if (entries.length != rawEntries.length) return null;
    final portablePaths = <String>{};
    for (final entry in entries) {
      if (entry.path.toLowerCase() == backupManifestEntryName ||
          !portablePaths.add(entry.path.toLowerCase())) {
        return null;
      }
    }
    for (final entry in entries) {
      final segments = entry.path.split('/');
      for (var length = 1; length < segments.length; length++) {
        if (portablePaths.contains(
          segments.take(length).join('/').toLowerCase(),
        )) {
          return null;
        }
      }
    }
    return BackupManifestV2(
      createdAt: createdAt,
      appVersion: value['appVersion']?.toString() ?? '',
      // Early Backup V2 manifests did not distinguish a filtered sync export
      // from a full manual export. Treat them as sync-scoped so device-only
      // credentials are never restored from an ambiguous file.
      isFullBackup: scope == 'full',
      entries: entries,
      hasExplicitScope: hasExplicitScope,
    );
  }
}

final class BackupEntryV2 {
  const BackupEntryV2({
    required this.path,
    required this.length,
    required this.sha256,
    required this.kind,
  });

  final String path;
  final int length;
  final String sha256;
  final String kind;

  Map<String, Object?> toJson() => {
    'path': path,
    'length': length,
    'sha256': sha256,
    'kind': kind,
  };

  static BackupEntryV2? tryParse(Object? value) {
    if (value is! Map) return null;
    final length = value['length'];
    final path = value['path'];
    final digest = value['sha256'];
    final kind = value['kind'];
    if (path is! String ||
        normalizeBackupEntryPath(path) != path ||
        length is! int ||
        length < 0 ||
        digest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        kind is! String ||
        kind.isEmpty) {
      return null;
    }
    return BackupEntryV2(
      path: path,
      length: length,
      sha256: digest,
      kind: kind,
    );
  }
}

final class BackupV2Payload {
  const BackupV2Payload(this.entries, this.manifest);

  final Map<String, Uint8List> entries;
  final BackupManifestV2 manifest;
}

/// Adds compatibility files to the same authenticated manifest as logical
/// rewrite data. V2 importers may ignore these entries, but they must never
/// install an unchecked legacy database or JSON snapshot.
BackupV2Payload extendBackupV2Payload(
  BackupV2Payload base,
  Map<String, Uint8List> additionalEntries, {
  String Function(String path)? kindForPath,
}) {
  final entries = <String, Uint8List>{...base.entries};
  final portablePaths = <String>{};
  for (final path in entries.keys) {
    if (!portablePaths.add(path.toLowerCase())) {
      throw FormatException('Case-insensitive backup path collision: $path');
    }
  }
  final baseKinds = <String, String>{
    for (final entry in base.manifest.entries) entry.path: entry.kind,
  };
  for (final entry in additionalEntries.entries) {
    final normalized = normalizeBackupEntryPath(entry.key);
    if (normalized == null ||
        entries.containsKey(normalized) ||
        !portablePaths.add(normalized.toLowerCase())) {
      throw FormatException('Invalid or duplicate backup entry: ${entry.key}');
    }
    entries[normalized] = entry.value;
  }
  final manifestEntries =
      entries.entries
          .map(
            (entry) => BackupEntryV2(
              path: entry.key,
              length: entry.value.length,
              sha256: sha256.convert(entry.value).toString(),
              kind: base.entries.containsKey(entry.key)
                  ? baseKinds[entry.key]!
                  : kindForPath?.call(entry.key) ?? 'compatibility',
            ),
          )
          .toList(growable: false)
        ..sort((a, b) => a.path.compareTo(b.path));
  return BackupV2Payload(
    entries,
    BackupManifestV2(
      createdAt: base.manifest.createdAt,
      appVersion: base.manifest.appVersion,
      isFullBackup: base.manifest.isFullBackup,
      entries: manifestEntries,
    ),
  );
}

/// Creates database-independent logical snapshots while legacy raw databases
/// continue to be included for backwards compatibility.
BackupV2Payload buildBackupV2Payload({
  required String dataPath,
  required String appVersion,
  bool useSyncAppdata = false,
  bool strict = false,
  String? localRoot,
  String? imageFavoriteAssetsPath,
}) {
  final payloads = <String, Uint8List>{};

  void addJson(String name, Object? value) {
    payloads['$backupLogicalDirectory/$name'] = Uint8List.fromList(
      utf8.encode(jsonEncode(value)),
    );
  }

  void addBytes(String path, List<int> value) {
    payloads[path] = Uint8List.fromList(value);
  }

  // `syncdata.json` is the existing filtered export representation. Keep the
  // logical V2 payload aligned with the legacy export so a normal backup does
  // not accidentally re-introduce fields intentionally omitted from sync.
  final syncAppdataFile = File(FilePath.join(dataPath, 'syncdata.json'));
  final appdataFile = useSyncAppdata && syncAppdataFile.existsSync()
      ? syncAppdataFile
      : File(FilePath.join(dataPath, 'appdata.json'));
  if (appdataFile.existsSync()) {
    try {
      addJson('appdata.json', jsonDecode(appdataFile.readAsStringSync()));
    } catch (error) {
      if (strict) {
        throw FormatException('Invalid backup appdata.json', error);
      }
      addJson('appdata.json', <String, Object?>{});
    }
  } else {
    addJson('appdata.json', <String, Object?>{});
  }

  if (!useSyncAppdata) {
    final implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
    if (implicitDataFile.existsSync()) {
      try {
        addJson(
          'implicit_data.json',
          jsonDecode(implicitDataFile.readAsStringSync()),
        );
      } catch (error) {
        if (strict) {
          throw FormatException('Invalid backup implicitData.json', error);
        }
        addJson('implicit_data.json', <String, Object?>{});
      }
    } else {
      addJson('implicit_data.json', <String, Object?>{});
    }
  }

  addJson(
    'history.json',
    _readHistoryDatabase(FilePath.join(dataPath, 'history.db'), strict: strict),
  );
  addJson(
    'image_favorites.json',
    _readDatabaseRows(
      FilePath.join(dataPath, 'history.db'),
      'SELECT * FROM image_favorites;',
      strict: strict,
      optionalTable: 'image_favorites',
    ),
  );
  addJson(
    'favorites.json',
    _readFavoriteDatabase(
      FilePath.join(dataPath, 'local_favorite.db'),
      strict: strict,
    ),
  );
  addJson(
    'cookies.json',
    _readDatabaseRows(
      FilePath.join(dataPath, 'cookie.db'),
      'SELECT * FROM cookies;',
      strict: strict,
      optionalTable: 'cookies',
    ),
  );
  if (!useSyncAppdata) {
    addJson(
      'download_tasks.json',
      _readJsonList(
        FilePath.join(dataPath, 'downloading_tasks.json'),
        strict: strict,
      ),
    );
    final imageFavoriteAssets = _readImageFavoriteAssets(
      imageFavoriteAssetsPath,
      strict: strict,
    );
    final imageFavoriteAssetIndex = imageFavoriteAssets
        .map((asset) {
          final encodedName = base64Url
              .encode(utf8.encode(asset.name))
              .replaceAll('=', '');
          final logicalPath =
              '$backupLogicalDirectory/image_favorite_assets/$encodedName';
          addBytes(logicalPath, asset.bytes);
          return <String, Object?>{
            'name': asset.name,
            'path': logicalPath,
            'length': asset.bytes.length,
            'sha256': asset.sha256,
          };
        })
        .toList(growable: false);
    addJson('image_favorite_assets.json', imageFavoriteAssetIndex);
  }
  addJson(
    'local_index.json',
    _readLocalIndex(dataPath, localRoot: localRoot, strict: strict),
  );

  final sourceDir = Directory(FilePath.join(dataPath, 'comic_source'));
  if (sourceDir.existsSync()) {
    final sources = sourceDir.listSync().whereType<File>().toList(
      growable: false,
    )..sort((a, b) => a.name.compareTo(b.name));
    final sourceIndex = sources
        .map((file) {
          final bytes = file.readAsBytesSync();
          final encodedName = base64Url
              .encode(utf8.encode(file.name))
              .replaceAll('=', '');
          final logicalPath = '$backupLogicalDirectory/sources/$encodedName';
          addBytes(logicalPath, bytes);
          return <String, Object?>{
            'name': file.name,
            'path': logicalPath,
            'length': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
          };
        })
        .toList(growable: false);
    addJson('sources.json', sourceIndex);
  } else {
    addJson('sources.json', const <Object?>[]);
  }

  final manifestEntries =
      payloads.entries
          .map(
            (entry) => BackupEntryV2(
              path: entry.key,
              length: entry.value.length,
              sha256: sha256.convert(entry.value).toString(),
              kind: entry.key.startsWith('$backupLogicalDirectory/sources/')
                  ? 'source_document'
                  : entry.key.startsWith(
                      '$backupLogicalDirectory/image_favorite_assets/',
                    )
                  ? 'image_favorite_asset'
                  : entry.key.split('/').last.replaceAll('.json', ''),
            ),
          )
          .toList(growable: false)
        ..sort((a, b) => a.path.compareTo(b.path));
  return BackupV2Payload(
    payloads,
    BackupManifestV2(
      createdAt: DateTime.now().toUtc(),
      appVersion: appVersion,
      isFullBackup: !useSyncAppdata,
      entries: manifestEntries,
    ),
  );
}

List<Map<String, Object?>> _readDatabaseRows(
  String path,
  String query, {
  bool strict = false,
  String? optionalTable,
}) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  Database? db;
  try {
    db = sqlite3.open(path, mode: OpenMode.readOnly);
    if (optionalTable != null && !_databaseTableExists(db, optionalTable)) {
      return const [];
    }
    return db
        .select(query)
        .map((row) => Map<String, Object?>.from(row))
        .toList(growable: false);
  } catch (error) {
    if (strict) {
      throw FormatException('Failed to read backup database: $path', error);
    }
    return const [];
  } finally {
    db?.close();
  }
}

List<Map<String, Object?>> _readHistoryDatabase(
  String path, {
  bool strict = false,
}) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  Database? database;
  try {
    database = sqlite3.open(path, mode: OpenMode.readOnly);
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table';")
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .toSet();
    final sourceTables = [
      if (tables.contains('history_legacy')) 'history_legacy',
      if (tables.contains('history')) 'history',
    ];
    if (sourceTables.isEmpty) {
      throw const FormatException('History database has no history table');
    }
    final byIdentity = <String, Map<String, Object?>>{};
    for (final table in sourceTables) {
      for (final raw in database.select('SELECT * FROM "$table";')) {
        final row = Map<String, Object?>.from(raw);
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) {
          throw const FormatException('History row has no comic id');
        }
        final explicitSource = row['source_key']?.toString();
        final type = _backupInt(row['type']);
        final sourceKey = explicitSource != null && explicitSource.isNotEmpty
            ? explicitSource
            : type == 0
            ? 'local'
            : 'Unknown:$type';
        row['id'] = id;
        row['source_key'] = sourceKey;
        byIdentity[jsonEncode([sourceKey, id])] = row;
      }
    }
    return byIdentity.values.toList(growable: false);
  } catch (error) {
    if (strict) {
      throw FormatException('Failed to read backup history: $path', error);
    }
    return const [];
  } finally {
    database?.close();
  }
}

int _backupInt(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

bool _databaseTableExists(Database db, String table) => db.select(
  "SELECT 1 FROM sqlite_master "
  "WHERE type = 'table' AND name = ? LIMIT 1;",
  [table],
).isNotEmpty;

List<Object?> _readJsonList(String path, {bool strict = false}) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is List) return decoded;
    if (strict) {
      throw FormatException('Backup JSON must contain an array: $path');
    }
    return const [];
  } catch (error) {
    if (strict) {
      rethrow;
    }
    return const [];
  }
}

List<({String name, Uint8List bytes, String sha256})> _readImageFavoriteAssets(
  String? path, {
  bool strict = false,
}) {
  if (path == null || path.isEmpty) return const [];
  final directory = Directory(path);
  if (!directory.existsSync()) return const [];
  try {
    final files =
        directory
            .listSync(followLinks: false)
            .whereType<File>()
            .toList(growable: false)
          ..sort((a, b) => a.name.compareTo(b.name));
    return files
        .map((file) {
          final bytes = file.readAsBytesSync();
          return (
            name: file.name,
            bytes: bytes,
            sha256: sha256.convert(bytes).toString(),
          );
        })
        .toList(growable: false);
  } catch (error) {
    if (strict) {
      throw FormatException('Failed to index image favorite assets', error);
    }
    return const [];
  }
}

Map<String, Object?> _readFavoriteDatabase(String path, {bool strict = false}) {
  final file = File(path);
  if (!file.existsSync()) return const {};
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    final result = <String, Object?>{};
    final tables = db
        .select(
          "SELECT name FROM sqlite_master WHERE type='table' AND "
          "name NOT LIKE 'sqlite_%';",
        )
        .map((row) => row['name']?.toString())
        .whereType<String>();
    for (final table in tables) {
      final escaped = table.replaceAll('"', '""');
      try {
        result[table] = db
            .select('SELECT * FROM "$escaped";')
            .map((row) => Map<String, Object?>.from(row))
            .toList(growable: false);
      } catch (error) {
        if (strict) {
          throw FormatException(
            'Failed to read backup favorites table: $table',
            error,
          );
        }
        // A malformed optional table should not make the entire backup fail.
      }
    }
    return result;
  } finally {
    db.close();
  }
}

Map<String, Object?> _readLocalIndex(
  String dataPath, {
  String? localRoot,
  bool strict = false,
}) {
  final dbPath = FilePath.join(dataPath, 'local.db');
  final localPathFile = File(FilePath.join(dataPath, 'local_path'));
  final resolvedLocalRoot =
      localRoot ??
      (localPathFile.existsSync()
          ? localPathFile.readAsStringSync()
          : FilePath.join(dataPath, 'local'));
  final rows = _readDatabaseRows(
    dbPath,
    'SELECT * FROM comics;',
    strict: strict,
  );
  final comics = rows
      .map((row) {
        final rawDirectory = row['directory']?.toString() ?? '';
        final isManagedDirectory =
            rawDirectory.isNotEmpty &&
            !rawDirectory.contains('/') &&
            !rawDirectory.contains('\\');
        final baseDir = isManagedDirectory
            ? FilePath.join(resolvedLocalRoot, rawDirectory)
            : rawDirectory;
        final metadata = Directory(FilePath.join(baseDir, '.venera'));
        final archive = File(FilePath.join(metadata.path, 'archive.zip'));
        final archiveExists = archive.existsSync();
        final storageState = !archiveExists
            ? 'loose'
            : File(FilePath.join(metadata.path, 'dirty')).existsSync()
            ? 'dirty'
            : File(FilePath.join(metadata.path, 'expanded.json')).existsSync()
            ? 'expanded'
            : 'archived';
        return <String, Object?>{
          ...row,
          'archive': <String, Object?>{
            'managed': isManagedDirectory,
            'relativePath': isManagedDirectory
                ? p.posix.join(rawDirectory, '.venera', 'archive.zip')
                : null,
            'originalPath': rawDirectory.isEmpty ? null : archive.path,
            'exists': archiveExists,
            'length': archiveExists ? archive.lengthSync() : null,
            'state': storageState,
          },
        };
      })
      .toList(growable: false);
  return <String, Object?>{'localRoot': resolvedLocalRoot, 'comics': comics};
}

bool verifyBackupV2Payload(
  BackupManifestV2 manifest,
  Map<String, Uint8List> entries,
) {
  for (final expected in manifest.entries) {
    final bytes = entries[expected.path];
    if (bytes == null ||
        bytes.length != expected.length ||
        sha256.convert(bytes).toString() != expected.sha256) {
      return false;
    }
  }
  return true;
}

/// Validates a V2 staging directory. A missing manifest identifies a legacy
/// backup and is intentionally accepted by the compatibility importer.
BackupManifestV2? validateExtractedBackupV2(Directory directory) {
  final manifestFile = File(
    FilePath.join(directory.path, backupManifestEntryName),
  );
  if (!manifestFile.existsSync()) return null;
  if (manifestFile.lengthSync() > maxBackupManifestBytes) {
    throw const FormatException('Backup manifest is too large');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(manifestFile.readAsStringSync());
  } catch (error) {
    throw FormatException('Invalid backup manifest JSON', error);
  }
  final manifest = BackupManifestV2.tryParse(decoded);
  if (manifest == null) {
    throw const FormatException('Unsupported backup manifest');
  }
  final declaredPaths = <String>{};
  for (final expected in manifest.entries) {
    if (!declaredPaths.add(expected.path.toLowerCase())) {
      throw FormatException('Duplicate backup entry: ${expected.path}');
    }
    final file = File(FilePath.join(directory.path, expected.path));
    if (!isPathInsideDirectory(file.path, directory.path) ||
        FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw FormatException('Missing backup entry: ${expected.path}');
    }
    if (file.lengthSync() != expected.length ||
        _sha256FileSync(file) != expected.sha256) {
      throw FormatException('Backup entry checksum mismatch: ${expected.path}');
    }
  }
  if (manifest.hasExplicitScope) {
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) continue;
      if (type != FileSystemEntityType.file) {
        throw FormatException('Unsupported backup entity: ${entity.path}');
      }
      final relative = p
          .relative(entity.path, from: directory.path)
          .replaceAll('\\', '/');
      if (relative == backupManifestEntryName) continue;
      final normalized = normalizeBackupEntryPath(relative);
      if (normalized != relative ||
          !declaredPaths.contains(relative.toLowerCase())) {
        throw FormatException('Unmanifested backup entry: $relative');
      }
    }
  }
  return manifest;
}

String _sha256FileSync(File file) {
  final output = _SingleDigestSink();
  final input = sha256.startChunkedConversion(output);
  final handle = file.openSync();
  try {
    final buffer = Uint8List(1024 * 1024);
    while (true) {
      final count = handle.readIntoSync(buffer);
      if (count == 0) break;
      // Do not hand the converter a buffer that will be mutated by the next
      // file read. The temporary allocation is bounded to one MiB.
      input.add(buffer.sublist(0, count));
    }
    input.close();
    return output.value!.toString();
  } finally {
    handle.closeSync();
  }
}

final class _SingleDigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    if (value != null) throw StateError('Hash converter emitted twice');
    value = data;
  }

  @override
  void close() {}
}

/// Validates the stricter backup contract required before a destructive
/// rewrite reset. Ordinary imports keep accepting earlier Backup V2 files,
/// whose newly added logical sections are optional.
BackupManifestV2 validateCompleteExtractedBackupV2(Directory directory) {
  final manifest = validateExtractedBackupV2(directory);
  if (manifest == null) {
    throw const FormatException('Backup V2 manifest is missing');
  }
  if (!manifest.isCompleteRewriteBackup) {
    throw const FormatException(
      'Backup is not a complete full snapshot for the rewrite',
    );
  }
  return manifest;
}
