import 'package:sqlite_async/sqlite_async.dart';
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/repositories/json_repository_support.dart';

abstract interface class SettingsRepository {
  Future<Map<String, Object?>> read();

  Stream<Map<String, Object?>> watch();

  Future<Object?> readValue(String key);

  Future<void> setValue(String key, Object? value);

  Future<void> setValues(Map<String, Object?> values);

  Future<void> removeValue(String key);

  Future<void> replaceAll(Map<String, Object?> settings);

  Future<void> update(
    Map<String, Object?> Function(Map<String, Object?> current) transform,
  );
}

/// Authoritative SQLite settings store for the rewritten application.
///
/// The whole settings object is updated in one SQLite transaction so two
/// concurrent field updates cannot partially overwrite each other.
final class SqliteSettingsRepository implements SettingsRepository {
  SqliteSettingsRepository(this._database);

  static const sectionKey = 'settings';

  final AppDatabase _database;

  @override
  Future<Map<String, Object?>> read() => _readFrom(_database.raw);

  @override
  Stream<Map<String, Object?>> watch() {
    return _database.raw
        .watch(
          'SELECT payload_json FROM app_state WHERE section_key = ?',
          parameters: const [sectionKey],
          triggerOnTables: const {'app_state'},
        )
        .map((rows) => _decodeRows(rows));
  }

  @override
  Future<Object?> readValue(String key) async => (await read())[key];

  @override
  Future<void> setValue(String key, Object? value) {
    _validateKey(key);
    return update((current) => <String, Object?>{...current, key: value});
  }

  @override
  Future<void> setValues(Map<String, Object?> values) {
    for (final key in values.keys) {
      _validateKey(key);
    }
    return update((current) => <String, Object?>{...current, ...values});
  }

  @override
  Future<void> removeValue(String key) {
    _validateKey(key);
    return update((current) {
      final next = <String, Object?>{...current};
      next.remove(key);
      return next;
    });
  }

  @override
  Future<void> replaceAll(Map<String, Object?> settings) async {
    for (final key in settings.keys) {
      _validateKey(key);
    }
    final encoded = encodeRepositoryJson(settings, context: 'settings payload');
    await _database.raw.execute(
      '''
      INSERT INTO app_state(section_key, payload_json) VALUES (?, ?)
      ON CONFLICT(section_key) DO UPDATE SET
        payload_json = excluded.payload_json
      ''',
      [sectionKey, encoded],
    );
  }

  @override
  Future<void> update(
    Map<String, Object?> Function(Map<String, Object?> current) transform,
  ) async {
    await _database.raw.writeTransaction((tx) async {
      final current = await _readFrom(tx);
      final next = transform(current);
      for (final key in next.keys) {
        _validateKey(key);
      }
      final encoded = encodeRepositoryJson(next, context: 'settings payload');
      await tx.execute(
        '''
        INSERT INTO app_state(section_key, payload_json) VALUES (?, ?)
        ON CONFLICT(section_key) DO UPDATE SET
          payload_json = excluded.payload_json
        ''',
        [sectionKey, encoded],
      );
    });
  }

  static Future<Map<String, Object?>> _readFrom(
    SqliteReadContext database,
  ) async {
    final row = await database.getOptional(
      'SELECT payload_json FROM app_state WHERE section_key = ?',
      const [sectionKey],
    );
    if (row == null) return const <String, Object?>{};
    return decodeRepositoryJsonObject(
      row['payload_json'] as String,
      context: 'settings payload',
    );
  }

  static Map<String, Object?> _decodeRows(Iterable<Object?> rows) {
    final values = rows.toList(growable: false);
    if (values.isEmpty) return const <String, Object?>{};
    final row = values.single as Map<Object?, Object?>;
    return decodeRepositoryJsonObject(
      row['payload_json'] as String,
      context: 'settings payload',
    );
  }

  static void _validateKey(String key) {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'must not be empty');
    }
  }
}
