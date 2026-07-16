import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera/core/database/app_database.dart';

void main() {
  test(
    'AppDatabase initializes once and supports async transactions',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'venera_app_database_test_',
      );
      final database = AppDatabase(
        path: path.join(tempDirectory.path, AppDatabase.fileName),
      );
      addTearDown(() async {
        await database.close();
        await tempDirectory.delete(recursive: true);
      });

      await database.initialize();
      await database.initialize();
      await database.raw.writeTransaction((tx) async {
        await tx.execute(
          'INSERT INTO app_metadata(key, value, updated_at) VALUES(?, ?, ?)',
          ['test', 'value', 1],
        );
      });

      final row = await database.raw.get(
        'SELECT value FROM app_metadata WHERE key = ?',
        ['test'],
      );
      expect(row['value'], 'value');
    },
  );

  test('AppDatabase rejects access before initialization', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'venera_app_database_uninitialized_test_',
    );
    final database = AppDatabase(
      path: path.join(tempDirectory.path, AppDatabase.fileName),
    );
    addTearDown(() async {
      await database.close();
      await tempDirectory.delete(recursive: true);
    });

    expect(() => database.raw, throwsStateError);
  });
}
