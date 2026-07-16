import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'io.dart';

const int currentBackupFormatVersion = 2;
const String backupManifestEntryName = 'manifest.json';
const String backupLogicalDirectory = 'logical';

final class BackupManifestV2 {
  const BackupManifestV2({
    required this.createdAt,
    required this.appVersion,
    required this.entries,
  });

  final DateTime createdAt;
  final String appVersion;
  final List<BackupEntryV2> entries;

  Map<String, Object?> toJson() => {
    'format': 'venera-backup',
    'version': currentBackupFormatVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'appVersion': appVersion,
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
    if (createdAt == null || rawEntries is! Iterable) return null;
    final entries = rawEntries
        .map(BackupEntryV2.tryParse)
        .whereType<BackupEntryV2>()
        .toList(growable: false);
    if (entries.length != rawEntries.length) return null;
    return BackupManifestV2(
      createdAt: createdAt,
      appVersion: value['appVersion']?.toString() ?? '',
      entries: entries,
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
        path.isEmpty ||
        length is! int ||
        length < 0 ||
        digest is! String ||
        digest.length != 64 ||
        kind is! String) {
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

/// Creates database-independent logical snapshots while legacy raw databases
/// continue to be included for backwards compatibility.
BackupV2Payload buildBackupV2Payload({
  required String dataPath,
  required String appVersion,
  bool useSyncAppdata = false,
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
    } catch (_) {
      addJson('appdata.json', <String, Object?>{});
    }
  }

  addJson(
    'history.json',
    _readDatabaseRows(
      FilePath.join(dataPath, 'history.db'),
      'SELECT * FROM history;',
    ),
  );
  addJson(
    'favorites.json',
    _readFavoriteDatabase(FilePath.join(dataPath, 'local_favorite.db')),
  );
  addJson('local_index.json', _readLocalIndex(dataPath));

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
      entries: manifestEntries,
    ),
  );
}

List<Map<String, Object?>> _readDatabaseRows(String path, String query) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return db
        .select(query)
        .map((row) => Map<String, Object?>.from(row))
        .toList(growable: false);
  } catch (_) {
    return const [];
  } finally {
    db.close();
  }
}

Map<String, Object?> _readFavoriteDatabase(String path) {
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
      } catch (_) {
        // A malformed optional table should not make the entire backup fail.
      }
    }
    return result;
  } finally {
    db.close();
  }
}

Map<String, Object?> _readLocalIndex(String dataPath) {
  final dbPath = FilePath.join(dataPath, 'local.db');
  final localPathFile = File(FilePath.join(dataPath, 'local_path'));
  final localRoot = localPathFile.existsSync()
      ? localPathFile.readAsStringSync()
      : FilePath.join(dataPath, 'local');
  final rows = _readDatabaseRows(dbPath, 'SELECT * FROM comics;');
  final comics = rows
      .map((row) {
        final rawDirectory = row['directory']?.toString() ?? '';
        final isManagedDirectory =
            rawDirectory.isNotEmpty &&
            !rawDirectory.contains('/') &&
            !rawDirectory.contains('\\');
        final baseDir = isManagedDirectory
            ? FilePath.join(localRoot, rawDirectory)
            : rawDirectory;
        final archive = File(FilePath.join(baseDir, '.venera', 'archive.zip'));
        return <String, Object?>{
          ...row,
          'archive': <String, Object?>{
            'managed': isManagedDirectory,
            'relativePath': isManagedDirectory
                ? p.posix.join(rawDirectory, '.venera', 'archive.zip')
                : null,
            'originalPath': rawDirectory.isEmpty ? null : archive.path,
            'exists': archive.existsSync(),
            'length': archive.existsSync() ? archive.lengthSync() : null,
          },
        };
      })
      .toList(growable: false);
  return <String, Object?>{'localRoot': localRoot, 'comics': comics};
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
  final entries = <String, Uint8List>{};
  for (final expected in manifest.entries) {
    final file = File(FilePath.join(directory.path, expected.path));
    if (!isPathInsideDirectory(file.path, directory.path) ||
        !file.existsSync()) {
      throw FormatException('Missing backup entry: ${expected.path}');
    }
    entries[expected.path] = file.readAsBytesSync();
  }
  if (!verifyBackupV2Payload(manifest, entries)) {
    throw const FormatException('Backup entry checksum mismatch');
  }
  return manifest;
}
