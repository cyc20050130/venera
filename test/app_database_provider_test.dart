import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/providers/app_providers.dart';

void main() {
  test(
    'app database provider initializes an overrideable shared database',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera-app-database-provider-',
      );
      final databasePath = path.join(directory.path, AppDatabase.fileName);
      final container = ProviderContainer(
        overrides: [appDatabasePathProvider.overrideWithValue(databasePath)],
      );
      addTearDown(() async {
        container.dispose();
        await Future<void>.delayed(Duration.zero);
        await directory.delete(recursive: true);
      });

      final database = await container.read(appDatabaseProvider.future);

      final rows = await database.raw.getAll(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'app_metadata'",
      );
      expect(rows, hasLength(1));
      expect(await container.read(appDatabaseProvider.future), same(database));
    },
  );
}
