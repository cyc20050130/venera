import 'package:sqlite_async/sqlite_async.dart';

/// The single asynchronous database used by newly migrated repositories.
///
/// Existing databases remain readable during the gradual migration. Features
/// move into this database one repository at a time, avoiding a destructive
/// all-at-once schema conversion.
final class AppDatabase {
  AppDatabase({required String path, SqliteDatabase? database})
    : _database = database ?? SqliteDatabase(path: path);

  static const fileName = 'venera.db';

  final SqliteDatabase _database;

  bool _initialized = false;

  SqliteDatabase get raw {
    if (!_initialized) {
      throw StateError('AppDatabase has not been initialized');
    }
    return _database;
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    await _migrations.migrate(_database);
    _initialized = true;
  }

  Future<void> close() => _database.close();

  static final SqliteMigrations _migrations = SqliteMigrations()
    ..add(
      SqliteMigration(1, (tx) async {
        // Future feature migrations store compatibility markers here instead
        // of coupling their schema state to a global singleton.
        await tx.execute('''
          CREATE TABLE app_metadata (
            key TEXT NOT NULL PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
      }),
    )
    ..add(
      SqliteMigration(2, (tx) async {
        // Backup V2 is intentionally database-independent. These tables are
        // the rewrite-side import target: the exact payload is retained in
        // [backup_payloads], while the other tables are queryable projections
        // that repositories can adopt incrementally.
        await tx.executeMultiple('''
          CREATE TABLE backup_import (
            singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
            format_version INTEGER NOT NULL,
            app_version TEXT NOT NULL,
            created_at TEXT NOT NULL,
            imported_at INTEGER NOT NULL
          );

          CREATE TABLE backup_payloads (
            path TEXT NOT NULL PRIMARY KEY,
            kind TEXT NOT NULL,
            content BLOB NOT NULL,
            sha256 TEXT NOT NULL,
            length INTEGER NOT NULL
          );

          CREATE TABLE app_state (
            section_key TEXT NOT NULL PRIMARY KEY,
            payload_json TEXT NOT NULL
          );

          CREATE TABLE reading_history (
            identity_key TEXT NOT NULL PRIMARY KEY,
            source_key TEXT NOT NULL,
            comic_id TEXT NOT NULL,
            payload_json TEXT NOT NULL
          );

          CREATE TABLE favorite_collections (
            collection_name TEXT NOT NULL PRIMARY KEY,
            payload_json TEXT NOT NULL
          );

          CREATE TABLE local_comics (
            identity_key TEXT NOT NULL PRIMARY KEY,
            comic_id TEXT NOT NULL,
            comic_type TEXT NOT NULL,
            directory TEXT NOT NULL,
            payload_json TEXT NOT NULL
          );

          CREATE TABLE local_archive_links (
            identity_key TEXT NOT NULL PRIMARY KEY,
            comic_id TEXT NOT NULL,
            comic_type TEXT NOT NULL,
            directory TEXT NOT NULL,
            original_root TEXT,
            relative_path TEXT,
            original_path TEXT,
            expected_length INTEGER,
            resolved_path TEXT,
            status TEXT NOT NULL CHECK (
              status IN ('available', 'missing', 'relinked')
            ),
            updated_at INTEGER NOT NULL
          );

          CREATE INDEX local_archive_links_status_index
            ON local_archive_links(status);

          CREATE TABLE source_documents (
            name TEXT NOT NULL PRIMARY KEY,
            content BLOB,
            sha256 TEXT NOT NULL,
            expected_length INTEGER NOT NULL,
            available INTEGER NOT NULL CHECK (available IN (0, 1))
          );
        ''');
      }),
    );
}
