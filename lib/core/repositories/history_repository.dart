import 'package:sqlite3/common.dart' show Row;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/domain/comic_key.dart';
import 'package:venera/core/repositories/json_repository_support.dart';

final class HistoryRecord {
  HistoryRecord({required this.key, required Map<String, Object?> payload})
    : payload = normalizeRepositoryJsonObject(
        payload,
        context: 'history payload',
      );

  factory HistoryRecord.fromRow(Row row) {
    final key = ComicKey(
      sourceKey: row['source_key'] as String,
      comicId: row['comic_id'] as String,
    );
    if (row['identity_key'] != key.storageKey) {
      throw const FormatException('History identity columns do not match');
    }
    return HistoryRecord(
      key: key,
      payload: decodeRepositoryJsonObject(
        row['payload_json'] as String,
        context: 'history payload',
      ),
    );
  }

  final ComicKey key;
  final Map<String, Object?> payload;

  int get timeMillis {
    final value = payload['time'];
    return switch (value) {
      int number => number,
      num number => number.toInt(),
      String text => int.tryParse(text) ?? 0,
      _ => 0,
    };
  }

  String get encodedPayload {
    final normalized = <String, Object?>{
      ...payload,
      'id': key.comicId,
      'source_key': key.sourceKey,
      'sourceKey': key.sourceKey,
    };
    return encodeRepositoryJson(normalized, context: 'history payload');
  }
}

abstract interface class HistoryRepository {
  Future<HistoryRecord?> get(ComicKey key);

  Future<List<HistoryRecord>> list({int limit = 100, int offset = 0});

  Stream<List<HistoryRecord>> watch({int limit = 100, int offset = 0});

  Future<int> count();

  Future<void> upsert(HistoryRecord record);

  Future<void> upsertAll(Iterable<HistoryRecord> records);

  Future<void> remove(ComicKey key);

  Future<void> removeAll(Iterable<ComicKey> keys);

  Future<void> clear();
}

/// Async, collision-free SQLite reading-history persistence.
final class SqliteHistoryRepository implements HistoryRepository {
  SqliteHistoryRepository(this._database);

  final AppDatabase _database;

  @override
  Future<HistoryRecord?> get(ComicKey key) async {
    final row = await _database.raw.getOptional(
      'SELECT * FROM reading_history WHERE identity_key = ?',
      [key.storageKey],
    );
    return row == null ? null : HistoryRecord.fromRow(row);
  }

  @override
  Future<List<HistoryRecord>> list({int limit = 100, int offset = 0}) async {
    _validatePage(limit: limit, offset: offset);
    final rows = await _database.raw.getAll(
      '''
      SELECT * FROM reading_history
      ORDER BY
        CAST(json_extract(payload_json, '\$.time') AS INTEGER) DESC,
        identity_key
      LIMIT ? OFFSET ?
      ''',
      [limit, offset],
    );
    return rows.map(HistoryRecord.fromRow).toList(growable: false);
  }

  @override
  Stream<List<HistoryRecord>> watch({int limit = 100, int offset = 0}) {
    _validatePage(limit: limit, offset: offset);
    return _database.raw
        .watch(
          '''
          SELECT * FROM reading_history
          ORDER BY
            CAST(json_extract(payload_json, '\$.time') AS INTEGER) DESC,
            identity_key
          LIMIT ? OFFSET ?
          ''',
          parameters: [limit, offset],
          triggerOnTables: const {'reading_history'},
        )
        .map((rows) => rows.map(HistoryRecord.fromRow).toList(growable: false));
  }

  @override
  Future<int> count() async {
    final row = await _database.raw.get(
      'SELECT COUNT(*) AS count FROM reading_history',
    );
    return row['count'] as int;
  }

  @override
  Future<void> upsert(HistoryRecord record) async {
    await _database.raw.execute(_upsertSql, _parameters(record));
  }

  @override
  Future<void> upsertAll(Iterable<HistoryRecord> records) async {
    final values = records.toList(growable: false);
    if (values.isEmpty) return;
    _ensureUnique(values.map((record) => record.key.storageKey));
    await _database.raw.writeTransaction((tx) async {
      await tx.executeBatch(
        _upsertSql,
        values.map(_parameters).toList(growable: false),
      );
    });
  }

  @override
  Future<void> remove(ComicKey key) async {
    await _database.raw.execute(
      'DELETE FROM reading_history WHERE identity_key = ?',
      [key.storageKey],
    );
  }

  @override
  Future<void> removeAll(Iterable<ComicKey> keys) async {
    final values = keys.map((key) => key.storageKey).toSet().toList();
    if (values.isEmpty) return;
    await _database.raw.writeTransaction((tx) async {
      await tx.executeBatch(
        'DELETE FROM reading_history WHERE identity_key = ?',
        values.map((key) => <Object?>[key]).toList(growable: false),
      );
    });
  }

  @override
  Future<void> clear() async {
    await _database.raw.execute('DELETE FROM reading_history');
  }

  static const _upsertSql = '''
    INSERT INTO reading_history(
      identity_key, source_key, comic_id, payload_json
    ) VALUES (?, ?, ?, ?)
    ON CONFLICT(identity_key) DO UPDATE SET
      source_key = excluded.source_key,
      comic_id = excluded.comic_id,
      payload_json = excluded.payload_json
  ''';

  static List<Object?> _parameters(HistoryRecord record) => <Object?>[
    record.key.storageKey,
    record.key.sourceKey,
    record.key.comicId,
    record.encodedPayload,
  ];

  static void _validatePage({required int limit, required int offset}) {
    if (limit < 1 || limit > 500) {
      throw RangeError.range(limit, 1, 500, 'limit');
    }
    if (offset < 0) throw RangeError.value(offset, 'offset');
  }

  static void _ensureUnique(Iterable<String> keys) {
    final seen = <String>{};
    for (final key in keys) {
      if (!seen.add(key)) {
        throw ArgumentError.value(key, 'records', 'contains a duplicate key');
      }
    }
  }
}
