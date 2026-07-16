import 'package:sqlite3/common.dart' show Row;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/domain/comic_key.dart';
import 'package:venera/core/repositories/json_repository_support.dart';

enum DownloadTaskState { queued, running, paused, completed, failed, cancelled }

extension DownloadTaskStateTerminal on DownloadTaskState {
  bool get isTerminal => switch (this) {
    DownloadTaskState.completed ||
    DownloadTaskState.failed ||
    DownloadTaskState.cancelled => true,
    _ => false,
  };
}

final class DownloadTaskRecord {
  DownloadTaskRecord({
    required this.id,
    required this.comicKey,
    required this.chapterId,
    required this.state,
    required this.completedUnits,
    required this.totalUnits,
    required Map<String, Object?> payload,
    required this.createdAtMillis,
    required this.updatedAtMillis,
  }) : payload = normalizeRepositoryJsonObject(
         payload,
         context: 'download task payload',
       ) {
    _validate();
  }

  factory DownloadTaskRecord.fromRow(Row row) {
    return DownloadTaskRecord(
      id: row['task_id'] as String,
      comicKey: ComicKey(
        sourceKey: row['source_key'] as String,
        comicId: row['comic_id'] as String,
      ),
      chapterId: row['chapter_id'] as String?,
      state: DownloadTaskState.values.byName(row['state'] as String),
      completedUnits: row['completed_units'] as int,
      totalUnits: row['total_units'] as int?,
      payload: decodeRepositoryJsonObject(
        row['payload_json'] as String,
        context: 'download task payload',
      ),
      createdAtMillis: row['created_at'] as int,
      updatedAtMillis: row['updated_at'] as int,
    );
  }

  final String id;
  final ComicKey comicKey;
  final String? chapterId;
  final DownloadTaskState state;
  final int completedUnits;
  final int? totalUnits;
  final Map<String, Object?> payload;
  final int createdAtMillis;
  final int updatedAtMillis;

  double? get fraction => totalUnits == null || totalUnits == 0
      ? null
      : completedUnits / totalUnits!;

  DownloadTaskRecord copyWith({
    DownloadTaskState? state,
    int? completedUnits,
    Object? totalUnits = _unset,
    Map<String, Object?>? payload,
    int? updatedAtMillis,
  }) {
    return DownloadTaskRecord(
      id: id,
      comicKey: comicKey,
      chapterId: chapterId,
      state: state ?? this.state,
      completedUnits: completedUnits ?? this.completedUnits,
      totalUnits: identical(totalUnits, _unset)
          ? this.totalUnits
          : totalUnits as int?,
      payload: payload ?? this.payload,
      createdAtMillis: createdAtMillis,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
    );
  }

  void _validate() {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    if (completedUnits < 0 ||
        totalUnits != null &&
            (totalUnits! < 0 || completedUnits > totalUnits!)) {
      throw const FormatException('Invalid download task progress');
    }
    if (createdAtMillis < 0 || updatedAtMillis < createdAtMillis) {
      throw const FormatException('Invalid download task timestamps');
    }
  }

  static const Object _unset = Object();
}

abstract interface class DownloadTaskRepository {
  Future<DownloadTaskRecord?> get(String id);

  Future<List<DownloadTaskRecord>> list({
    Set<DownloadTaskState>? states,
    int limit = 200,
  });

  Stream<List<DownloadTaskRecord>> watch({
    Set<DownloadTaskState>? states,
    int limit = 200,
  });

  Future<void> upsert(DownloadTaskRecord task);

  Future<void> upsertAll(Iterable<DownloadTaskRecord> tasks);

  Future<DownloadTaskRecord> updateProgress(
    String id, {
    required int completedUnits,
    required int? totalUnits,
  });

  Future<DownloadTaskRecord> updateState(String id, DownloadTaskState state);

  Future<int> recoverInterrupted();

  Future<void> remove(String id);

  Future<int> clearTerminal();
}

final class SqliteDownloadTaskRepository implements DownloadTaskRepository {
  SqliteDownloadTaskRepository(this._database, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _database;
  final DateTime Function() _clock;

  @override
  Future<DownloadTaskRecord?> get(String id) async {
    final row = await _database.raw.getOptional(
      'SELECT * FROM download_tasks WHERE task_id = ?',
      [id],
    );
    return row == null ? null : DownloadTaskRecord.fromRow(row);
  }

  @override
  Future<List<DownloadTaskRecord>> list({
    Set<DownloadTaskState>? states,
    int limit = 200,
  }) async {
    _validateLimit(limit);
    final query = _listQuery(states: states, limit: limit);
    final rows = await _database.raw.getAll(query.sql, query.parameters);
    return rows.map(DownloadTaskRecord.fromRow).toList(growable: false);
  }

  @override
  Stream<List<DownloadTaskRecord>> watch({
    Set<DownloadTaskState>? states,
    int limit = 200,
  }) {
    _validateLimit(limit);
    final query = _listQuery(states: states, limit: limit);
    return _database.raw
        .watch(
          query.sql,
          parameters: query.parameters,
          triggerOnTables: const {'download_tasks'},
        )
        .map(
          (rows) =>
              rows.map(DownloadTaskRecord.fromRow).toList(growable: false),
        );
  }

  @override
  Future<void> upsert(DownloadTaskRecord task) async {
    await _database.raw.execute(_upsertSql, _parameters(task));
  }

  @override
  Future<void> upsertAll(Iterable<DownloadTaskRecord> tasks) async {
    final values = tasks.toList(growable: false);
    if (values.isEmpty) return;
    final ids = <String>{};
    for (final value in values) {
      if (!ids.add(value.id)) {
        throw ArgumentError.value(value.id, 'tasks', 'contains a duplicate id');
      }
    }
    await _database.raw.writeTransaction((tx) async {
      await tx.executeBatch(
        _upsertSql,
        values.map(_parameters).toList(growable: false),
      );
    });
  }

  @override
  Future<DownloadTaskRecord> updateProgress(
    String id, {
    required int completedUnits,
    required int? totalUnits,
  }) async {
    final updatedAt = _nowMillis();
    return _database.raw.writeTransaction((tx) async {
      final row = await tx.getOptional(
        'SELECT * FROM download_tasks WHERE task_id = ?',
        [id],
      );
      if (row == null) throw StateError('Download task does not exist: $id');
      final next = DownloadTaskRecord.fromRow(row).copyWith(
        completedUnits: completedUnits,
        totalUnits: totalUnits,
        updatedAtMillis: updatedAt,
      );
      await tx.execute(_upsertSql, _parameters(next));
      return next;
    });
  }

  @override
  Future<DownloadTaskRecord> updateState(
    String id,
    DownloadTaskState state,
  ) async {
    final updatedAt = _nowMillis();
    return _database.raw.writeTransaction((tx) async {
      final row = await tx.getOptional(
        'SELECT * FROM download_tasks WHERE task_id = ?',
        [id],
      );
      if (row == null) throw StateError('Download task does not exist: $id');
      final next = DownloadTaskRecord.fromRow(
        row,
      ).copyWith(state: state, updatedAtMillis: updatedAt);
      await tx.execute(_upsertSql, _parameters(next));
      return next;
    });
  }

  /// Running work cannot survive process termination. Requeue it at startup.
  @override
  Future<int> recoverInterrupted() async {
    return _database.raw.writeTransaction((tx) async {
      final current = await tx.get(
        "SELECT COUNT(*) AS count FROM download_tasks WHERE state = 'running'",
      );
      final count = current['count'] as int;
      if (count == 0) return 0;
      await tx.execute(
        '''
        UPDATE download_tasks
        SET state = 'queued', updated_at = ?
        WHERE state = 'running'
        ''',
        [_nowMillis()],
      );
      return count;
    });
  }

  @override
  Future<void> remove(String id) async {
    await _database.raw.execute(
      'DELETE FROM download_tasks WHERE task_id = ?',
      [id],
    );
  }

  @override
  Future<int> clearTerminal() async {
    return _database.raw.writeTransaction((tx) async {
      final row = await tx.get('''
        SELECT COUNT(*) AS count FROM download_tasks
        WHERE state IN ('completed', 'failed', 'cancelled')
        ''');
      final count = row['count'] as int;
      if (count == 0) return 0;
      await tx.execute(
        "DELETE FROM download_tasks WHERE state IN ('completed', 'failed', 'cancelled')",
      );
      return count;
    });
  }

  int _nowMillis() => _clock().toUtc().millisecondsSinceEpoch;

  static _DownloadTaskQuery _listQuery({
    required Set<DownloadTaskState>? states,
    required int limit,
  }) {
    final values = states?.toList(growable: false)
      ?..sort((a, b) => a.index.compareTo(b.index));
    final where = switch (values) {
      null => '',
      [] => 'WHERE 0',
      _ => 'WHERE state IN (${List.filled(values.length, '?').join(', ')})',
    };
    return _DownloadTaskQuery(
      '''
      SELECT * FROM download_tasks
      $where
      ORDER BY
        CASE state
          WHEN 'running' THEN 0
          WHEN 'queued' THEN 1
          WHEN 'paused' THEN 2
          WHEN 'failed' THEN 3
          WHEN 'completed' THEN 4
          ELSE 5
        END,
        updated_at DESC,
        task_id
      LIMIT ?
      ''',
      <Object?>[...?values?.map((state) => state.name), limit],
    );
  }

  static const _upsertSql = '''
    INSERT INTO download_tasks(
      task_id, source_key, comic_id, chapter_id, state,
      completed_units, total_units, payload_json, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(task_id) DO UPDATE SET
      source_key = excluded.source_key,
      comic_id = excluded.comic_id,
      chapter_id = excluded.chapter_id,
      state = excluded.state,
      completed_units = excluded.completed_units,
      total_units = excluded.total_units,
      payload_json = excluded.payload_json,
      created_at = excluded.created_at,
      updated_at = excluded.updated_at
  ''';

  static List<Object?> _parameters(DownloadTaskRecord task) => [
    task.id,
    task.comicKey.sourceKey,
    task.comicKey.comicId,
    task.chapterId,
    task.state.name,
    task.completedUnits,
    task.totalUnits,
    encodeRepositoryJson(task.payload, context: 'download task payload'),
    task.createdAtMillis,
    task.updatedAtMillis,
  ];

  static void _validateLimit(int limit) {
    if (limit < 1 || limit > 1000) {
      throw RangeError.range(limit, 1, 1000, 'limit');
    }
  }
}

final class _DownloadTaskQuery {
  const _DownloadTaskQuery(this.sql, this.parameters);

  final String sql;
  final List<Object?> parameters;
}
