import 'package:sqlite3/common.dart' show Row;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/repositories/json_repository_support.dart';

/// A logical collection imported from, or written for, the favorites domain.
///
/// During the rewrite the payload stays format-independent. Consumers can
/// migrate one collection shape at a time without reopening the legacy DB.
final class FavoriteCollectionRecord {
  FavoriteCollectionRecord({required this.name, required Object? payload})
    : payload = normalizeRepositoryJson(
        payload,
        context: 'favorite collection payload',
      ) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
  }

  factory FavoriteCollectionRecord.fromRow(Row row) {
    return FavoriteCollectionRecord(
      name: row['collection_name'] as String,
      payload: decodeRepositoryJson(
        row['payload_json'] as String,
        context: 'favorite collection payload',
      ),
    );
  }

  final String name;
  final Object? payload;

  String get encodedPayload =>
      encodeRepositoryJson(payload, context: 'favorite collection payload');
}

abstract interface class FavoritesRepository {
  Future<FavoriteCollectionRecord?> get(String name);

  Future<List<FavoriteCollectionRecord>> list();

  Stream<List<FavoriteCollectionRecord>> watch();

  Future<void> upsert(FavoriteCollectionRecord collection);

  Future<void> replaceAll(Iterable<FavoriteCollectionRecord> collections);

  Future<void> remove(String name);

  Future<void> clear();
}

final class SqliteFavoritesRepository implements FavoritesRepository {
  SqliteFavoritesRepository(this._database);

  final AppDatabase _database;

  @override
  Future<FavoriteCollectionRecord?> get(String name) async {
    final row = await _database.raw.getOptional(
      'SELECT * FROM favorite_collections WHERE collection_name = ?',
      [name],
    );
    return row == null ? null : FavoriteCollectionRecord.fromRow(row);
  }

  @override
  Future<List<FavoriteCollectionRecord>> list() async {
    final rows = await _database.raw.getAll(
      'SELECT * FROM favorite_collections ORDER BY collection_name COLLATE NOCASE',
    );
    return rows.map(FavoriteCollectionRecord.fromRow).toList(growable: false);
  }

  @override
  Stream<List<FavoriteCollectionRecord>> watch() {
    return _database.raw
        .watch(
          'SELECT * FROM favorite_collections '
          'ORDER BY collection_name COLLATE NOCASE',
          triggerOnTables: const {'favorite_collections'},
        )
        .map(
          (rows) => rows
              .map(FavoriteCollectionRecord.fromRow)
              .toList(growable: false),
        );
  }

  @override
  Future<void> upsert(FavoriteCollectionRecord collection) async {
    await _database.raw.execute(_upsertSql, _parameters(collection));
  }

  /// Atomically replaces every collection, including ordering/sync metadata.
  @override
  Future<void> replaceAll(
    Iterable<FavoriteCollectionRecord> collections,
  ) async {
    final values = collections.toList(growable: false);
    _ensureUnique(values);
    await _database.raw.writeTransaction((tx) async {
      await tx.execute('DELETE FROM favorite_collections');
      if (values.isNotEmpty) {
        await tx.executeBatch(
          _upsertSql,
          values.map(_parameters).toList(growable: false),
        );
      }
    });
  }

  @override
  Future<void> remove(String name) async {
    await _database.raw.execute(
      'DELETE FROM favorite_collections WHERE collection_name = ?',
      [name],
    );
  }

  @override
  Future<void> clear() async {
    await _database.raw.execute('DELETE FROM favorite_collections');
  }

  static const _upsertSql = '''
    INSERT INTO favorite_collections(collection_name, payload_json)
    VALUES (?, ?)
    ON CONFLICT(collection_name) DO UPDATE SET
      payload_json = excluded.payload_json
  ''';

  static List<Object?> _parameters(FavoriteCollectionRecord collection) => [
    collection.name,
    collection.encodedPayload,
  ];

  static void _ensureUnique(List<FavoriteCollectionRecord> values) {
    final seen = <String>{};
    for (final value in values) {
      if (!seen.add(value.name)) {
        throw ArgumentError.value(
          value.name,
          'collections',
          'contains a duplicate name',
        );
      }
    }
  }
}
