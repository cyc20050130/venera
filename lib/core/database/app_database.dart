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
        // the rewrite-side queryable projections. [backup_payloads] remains
        // for schema compatibility but imports no longer duplicate complete
        // backup files (including images) into the database.
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
    )
    ..add(
      SqliteMigration(3, (tx) async {
        await tx.executeMultiple('''
          CREATE INDEX reading_history_source_index
            ON reading_history(source_key, comic_id);

          CREATE INDEX reading_history_time_index
            ON reading_history(
              CAST(json_extract(payload_json, '\$.time') AS INTEGER) DESC,
              identity_key
            );

          CREATE TRIGGER reading_history_validate_insert
          BEFORE INSERT ON reading_history
          WHEN NEW.identity_key != json_array(NEW.source_key, NEW.comic_id)
          BEGIN
            SELECT RAISE(ABORT, 'invalid history identity');
          END;

          CREATE TRIGGER reading_history_validate_update
          BEFORE UPDATE ON reading_history
          WHEN NEW.identity_key != json_array(NEW.source_key, NEW.comic_id)
          BEGIN
            SELECT RAISE(ABORT, 'invalid history identity');
          END;

          CREATE INDEX local_comics_type_index
            ON local_comics(comic_type, comic_id);

          CREATE TRIGGER local_comics_validate_insert
          BEFORE INSERT ON local_comics
          WHEN NEW.identity_key != json_array(NEW.comic_type, NEW.comic_id)
          BEGIN
            SELECT RAISE(ABORT, 'invalid local comic identity');
          END;

          CREATE TRIGGER local_comics_validate_update
          BEFORE UPDATE ON local_comics
          WHEN NEW.identity_key != json_array(NEW.comic_type, NEW.comic_id)
          BEGIN
            SELECT RAISE(ABORT, 'invalid local comic identity');
          END;

          CREATE TRIGGER local_archive_links_validate_insert
          BEFORE INSERT ON local_archive_links
          WHEN
            NEW.expected_length < 0 OR
            NEW.updated_at < 0 OR
            NOT EXISTS (
              SELECT 1 FROM local_comics
              WHERE identity_key = NEW.identity_key
                AND comic_id = NEW.comic_id
                AND comic_type = NEW.comic_type
                AND directory = NEW.directory
            )
          BEGIN
            SELECT RAISE(ABORT, 'invalid local archive link');
          END;

          CREATE TRIGGER local_archive_links_validate_update
          BEFORE UPDATE ON local_archive_links
          WHEN
            NEW.expected_length < 0 OR
            NEW.updated_at < 0 OR
            NOT EXISTS (
              SELECT 1 FROM local_comics
              WHERE identity_key = NEW.identity_key
                AND comic_id = NEW.comic_id
                AND comic_type = NEW.comic_type
                AND directory = NEW.directory
            )
          BEGIN
            SELECT RAISE(ABORT, 'invalid local archive link');
          END;

          CREATE TRIGGER local_comics_delete_archive_link
          AFTER DELETE ON local_comics
          BEGIN
            DELETE FROM local_archive_links
            WHERE identity_key = OLD.identity_key;
          END;

          CREATE TRIGGER local_comics_sync_archive_link
          AFTER UPDATE OF comic_id, comic_type, directory ON local_comics
          BEGIN
            UPDATE local_archive_links
            SET comic_id = NEW.comic_id,
                comic_type = NEW.comic_type,
                directory = NEW.directory
            WHERE identity_key = NEW.identity_key;
          END;

          CREATE INDEX source_documents_available_index
            ON source_documents(available, name);

          CREATE TABLE download_tasks (
            task_id TEXT NOT NULL PRIMARY KEY,
            source_key TEXT NOT NULL,
            comic_id TEXT NOT NULL,
            chapter_id TEXT,
            state TEXT NOT NULL CHECK (
              state IN (
                'queued', 'running', 'paused',
                'completed', 'failed', 'cancelled'
              )
            ),
            completed_units INTEGER NOT NULL DEFAULT 0
              CHECK (completed_units >= 0),
            total_units INTEGER CHECK (
              total_units IS NULL OR total_units >= 0
            ),
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            CHECK (
              total_units IS NULL OR completed_units <= total_units
            )
          );

          CREATE INDEX download_tasks_state_updated_index
            ON download_tasks(state, updated_at DESC);

          CREATE INDEX download_tasks_comic_index
            ON download_tasks(source_key, comic_id, chapter_id);
        ''');
      }),
    )
    ..add(
      SqliteMigration(4, (tx) async {
        await tx.executeMultiple('''
          CREATE TABLE cookies (
            name TEXT NOT NULL,
            value TEXT NOT NULL,
            domain TEXT NOT NULL,
            path TEXT NOT NULL,
            expires INTEGER CHECK (expires IS NULL OR expires >= 0),
            secure INTEGER NOT NULL CHECK (secure IN (0, 1)),
            http_only INTEGER NOT NULL CHECK (http_only IN (0, 1)),
            PRIMARY KEY (name, domain, path)
          );

          CREATE INDEX cookies_domain_index
            ON cookies(domain, path);

          CREATE TABLE image_favorites (
            identity_key TEXT NOT NULL PRIMARY KEY,
            source_key TEXT NOT NULL,
            comic_id TEXT NOT NULL,
            payload_json TEXT NOT NULL
          );

          CREATE INDEX image_favorites_source_index
            ON image_favorites(source_key, comic_id);
        ''');
      }),
    )
    ..add(
      SqliteMigration(5, (tx) async {
        await tx.executeMultiple('''
          -- Keep an archive link attached when a maintenance/import task
          -- changes every component of a local comic identity in one update.
          -- The migration-3 trigger only followed directory changes because
          -- it searched for NEW.identity_key instead of the previous key.
          DROP TRIGGER local_comics_sync_archive_link;

          CREATE TRIGGER local_comics_sync_archive_link
          AFTER UPDATE OF identity_key, comic_id, comic_type, directory
          ON local_comics
          BEGIN
            UPDATE local_archive_links
            SET identity_key = NEW.identity_key,
                comic_id = NEW.comic_id,
                comic_type = NEW.comic_type,
                directory = NEW.directory
            WHERE identity_key = OLD.identity_key;
          END;

          CREATE TRIGGER image_favorites_validate_insert
          BEFORE INSERT ON image_favorites
          WHEN NEW.identity_key != json_array(NEW.source_key, NEW.comic_id)
          BEGIN
            SELECT RAISE(ABORT, 'invalid image favorite identity');
          END;

          CREATE TRIGGER image_favorites_validate_update
          BEFORE UPDATE ON image_favorites
          WHEN NEW.identity_key != json_array(NEW.source_key, NEW.comic_id)
          BEGIN
            SELECT RAISE(ABORT, 'invalid image favorite identity');
          END;
        ''');
      }),
    );
}
