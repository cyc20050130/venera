import 'package:sqlite3/common.dart' show Row;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/domain/local_comic_key.dart';
import 'package:venera/core/repositories/json_repository_support.dart';

enum LocalArchiveLinkStatus { available, missing, relinked }

final class LocalComicRecord {
  LocalComicRecord({
    required this.key,
    required this.directory,
    required Map<String, Object?> payload,
  }) : payload = normalizeRepositoryJsonObject(
         payload,
         context: 'local comic payload',
       );

  factory LocalComicRecord.fromRow(Row row) {
    final key = LocalComicKey(
      comicType: row['comic_type'] as String,
      comicId: row['comic_id'] as String,
    );
    if (row['identity_key'] != key.storageKey) {
      throw const FormatException('Local comic identity columns do not match');
    }
    return LocalComicRecord(
      key: key,
      directory: row['directory'] as String,
      payload: decodeRepositoryJsonObject(
        row['payload_json'] as String,
        context: 'local comic payload',
      ),
    );
  }

  final LocalComicKey key;
  final String directory;
  final Map<String, Object?> payload;

  String get encodedPayload => encodeRepositoryJson(<String, Object?>{
    ...payload,
    'id': key.comicId,
    'comic_type': key.comicType,
    'directory': directory,
  }, context: 'local comic payload');
}

final class LocalArchiveLinkRecord {
  const LocalArchiveLinkRecord({
    required this.key,
    required this.directory,
    required this.originalRoot,
    required this.relativePath,
    required this.originalPath,
    required this.expectedLength,
    required this.resolvedPath,
    required this.status,
    required this.updatedAtMillis,
  });

  factory LocalArchiveLinkRecord.fromRow(Row row) {
    final key = LocalComicKey(
      comicType: row['archive_comic_type'] as String,
      comicId: row['archive_comic_id'] as String,
    );
    if (row['archive_identity_key'] != key.storageKey) {
      throw const FormatException('Archive link identity columns do not match');
    }
    final expectedLength = row['expected_length'];
    final updatedAt = row['archive_updated_at'];
    if (expectedLength != null &&
        (expectedLength is! int || expectedLength < 0)) {
      throw const FormatException('Invalid archive expected length');
    }
    if (updatedAt is! int || updatedAt < 0) {
      throw const FormatException('Invalid archive updated time');
    }
    return LocalArchiveLinkRecord(
      key: key,
      directory: row['archive_directory'] as String,
      originalRoot: row['original_root'] as String?,
      relativePath: row['relative_path'] as String?,
      originalPath: row['original_path'] as String?,
      expectedLength: expectedLength as int?,
      resolvedPath: row['resolved_path'] as String?,
      status: LocalArchiveLinkStatus.values.byName(
        row['archive_status'] as String,
      ),
      updatedAtMillis: updatedAt,
    );
  }

  final LocalComicKey key;
  final String directory;
  final String? originalRoot;
  final String? relativePath;
  final String? originalPath;
  final int? expectedLength;
  final String? resolvedPath;
  final LocalArchiveLinkStatus status;
  final int updatedAtMillis;
}

final class LocalLibraryEntry {
  const LocalLibraryEntry({required this.comic, required this.archive});

  factory LocalLibraryEntry.fromRow(Row row) {
    return LocalLibraryEntry(
      comic: LocalComicRecord.fromRow(row),
      archive: row['archive_identity_key'] == null
          ? null
          : LocalArchiveLinkRecord.fromRow(row),
    );
  }

  final LocalComicRecord comic;
  final LocalArchiveLinkRecord? archive;
}

abstract interface class LocalLibraryRepository {
  Future<LocalLibraryEntry?> get(LocalComicKey key);

  Future<List<LocalLibraryEntry>> list({LocalArchiveLinkStatus? archiveStatus});

  Stream<List<LocalLibraryEntry>> watch({
    LocalArchiveLinkStatus? archiveStatus,
  });

  Future<void> upsertComic(LocalComicRecord comic);

  Future<void> upsertComics(Iterable<LocalComicRecord> comics);

  Future<void> upsertArchiveLink(LocalArchiveLinkRecord link);

  Future<void> remove(LocalComicKey key);

  Future<void> clearIndex();
}

final class SqliteLocalLibraryRepository implements LocalLibraryRepository {
  SqliteLocalLibraryRepository(this._database);

  final AppDatabase _database;

  @override
  Future<LocalLibraryEntry?> get(LocalComicKey key) async {
    final row = await _database.raw.getOptional(
      '$_selectSql WHERE comics.identity_key = ?',
      [key.storageKey],
    );
    return row == null ? null : LocalLibraryEntry.fromRow(row);
  }

  @override
  Future<List<LocalLibraryEntry>> list({
    LocalArchiveLinkStatus? archiveStatus,
  }) async {
    final rows = await _database.raw.getAll('''
      $_selectSql
      ${archiveStatus == null ? '' : 'WHERE archives.status = ?'}
      ORDER BY
        lower(COALESCE(json_extract(comics.payload_json, '\$.title'), '')),
        comics.comic_id
      ''', archiveStatus == null ? const [] : [archiveStatus.name]);
    return rows.map(LocalLibraryEntry.fromRow).toList(growable: false);
  }

  @override
  Stream<List<LocalLibraryEntry>> watch({
    LocalArchiveLinkStatus? archiveStatus,
  }) {
    return _database.raw
        .watch(
          '''
          $_selectSql
          ${archiveStatus == null ? '' : 'WHERE archives.status = ?'}
          ORDER BY
            lower(COALESCE(json_extract(comics.payload_json, '\$.title'), '')),
            comics.comic_id
          ''',
          parameters: archiveStatus == null ? const [] : [archiveStatus.name],
          triggerOnTables: const {'local_comics', 'local_archive_links'},
        )
        .map(
          (rows) => rows.map(LocalLibraryEntry.fromRow).toList(growable: false),
        );
  }

  @override
  Future<void> upsertComic(LocalComicRecord comic) async {
    await _database.raw.execute(_upsertComicSql, _comicParameters(comic));
  }

  @override
  Future<void> upsertComics(Iterable<LocalComicRecord> comics) async {
    final values = comics.toList(growable: false);
    if (values.isEmpty) return;
    _ensureUnique(values.map((comic) => comic.key.storageKey));
    await _database.raw.writeTransaction((tx) async {
      await tx.executeBatch(
        _upsertComicSql,
        values.map(_comicParameters).toList(growable: false),
      );
    });
  }

  @override
  Future<void> upsertArchiveLink(LocalArchiveLinkRecord link) async {
    if (link.expectedLength != null && link.expectedLength! < 0) {
      throw ArgumentError.value(
        link.expectedLength,
        'link.expectedLength',
        'must not be negative',
      );
    }
    if (link.updatedAtMillis < 0) {
      throw ArgumentError.value(
        link.updatedAtMillis,
        'link.updatedAtMillis',
        'must not be negative',
      );
    }
    await _database.raw.writeTransaction((tx) async {
      final comic = await tx.getOptional(
        'SELECT directory FROM local_comics WHERE identity_key = ?',
        [link.key.storageKey],
      );
      if (comic == null) {
        throw StateError('Archive link requires an existing local comic');
      }
      if (comic['directory'] != link.directory) {
        throw ArgumentError.value(
          link.directory,
          'link.directory',
          'must match the local comic directory',
        );
      }
      await tx.execute(_upsertArchiveSql, _archiveParameters(link));
    });
  }

  @override
  Future<void> remove(LocalComicKey key) async {
    await _database.raw.writeTransaction((tx) async {
      await tx.execute(
        'DELETE FROM local_archive_links WHERE identity_key = ?',
        [key.storageKey],
      );
      await tx.execute('DELETE FROM local_comics WHERE identity_key = ?', [
        key.storageKey,
      ]);
    });
  }

  @override
  Future<void> clearIndex() async {
    await _database.raw.writeTransaction((tx) async {
      await tx.execute('DELETE FROM local_archive_links');
      await tx.execute('DELETE FROM local_comics');
    });
  }

  static const _selectSql = '''
    SELECT
      comics.*,
      archives.identity_key AS archive_identity_key,
      archives.comic_id AS archive_comic_id,
      archives.comic_type AS archive_comic_type,
      archives.directory AS archive_directory,
      archives.original_root,
      archives.relative_path,
      archives.original_path,
      archives.expected_length,
      archives.resolved_path,
      archives.status AS archive_status,
      archives.updated_at AS archive_updated_at
    FROM local_comics AS comics
    LEFT JOIN local_archive_links AS archives
      ON archives.identity_key = comics.identity_key
  ''';

  static const _upsertComicSql = '''
    INSERT INTO local_comics(
      identity_key, comic_id, comic_type, directory, payload_json
    ) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(identity_key) DO UPDATE SET
      comic_id = excluded.comic_id,
      comic_type = excluded.comic_type,
      directory = excluded.directory,
      payload_json = excluded.payload_json
  ''';

  static const _upsertArchiveSql = '''
    INSERT INTO local_archive_links(
      identity_key, comic_id, comic_type, directory, original_root,
      relative_path, original_path, expected_length, resolved_path,
      status, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(identity_key) DO UPDATE SET
      comic_id = excluded.comic_id,
      comic_type = excluded.comic_type,
      directory = excluded.directory,
      original_root = excluded.original_root,
      relative_path = excluded.relative_path,
      original_path = excluded.original_path,
      expected_length = excluded.expected_length,
      resolved_path = excluded.resolved_path,
      status = excluded.status,
      updated_at = excluded.updated_at
  ''';

  static List<Object?> _comicParameters(LocalComicRecord comic) => [
    comic.key.storageKey,
    comic.key.comicId,
    comic.key.comicType,
    comic.directory,
    comic.encodedPayload,
  ];

  static List<Object?> _archiveParameters(LocalArchiveLinkRecord link) => [
    link.key.storageKey,
    link.key.comicId,
    link.key.comicType,
    link.directory,
    link.originalRoot,
    link.relativePath,
    link.originalPath,
    link.expectedLength,
    link.resolvedPath,
    link.status.name,
    link.updatedAtMillis,
  ];

  static void _ensureUnique(Iterable<String> keys) {
    final seen = <String>{};
    for (final key in keys) {
      if (!seen.add(key)) {
        throw ArgumentError.value(key, 'comics', 'contains a duplicate key');
      }
    }
  }
}
