import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';

/// Compatibility providers used while global managers are migrated feature by
/// feature. New view models depend on providers instead of reading [App]
/// directly, which also makes them overrideable in tests.
final appdataProvider = Provider<Appdata>((ref) => appdata);

final historyManagerProvider = Provider<HistoryManager>((ref) => App.history);

final favoritesManagerProvider = Provider<LocalFavoritesManager>(
  (ref) => App.favorites,
);

final localManagerProvider = Provider<LocalManager>((ref) => App.local);

final appDatabasePathProvider = Provider<String>((ref) {
  if (!App.isInitialized) {
    throw StateError('App paths are not initialized');
  }
  return path.join(App.dataPath, AppDatabase.fileName);
});

final appDatabaseProvider =
    AsyncNotifierProvider<AppDatabaseNotifier, AppDatabase>(
      AppDatabaseNotifier.new,
    );

final class AppDatabaseNotifier extends AsyncNotifier<AppDatabase> {
  @override
  Future<AppDatabase> build() async {
    final database = AppDatabase(path: ref.watch(appDatabasePathProvider));
    try {
      await database.initialize();
    } catch (error, stackTrace) {
      await database.close();
      Error.throwWithStackTrace(error, stackTrace);
    }
    ref.onDispose(() => unawaited(database.close()));
    return database;
  }
}
