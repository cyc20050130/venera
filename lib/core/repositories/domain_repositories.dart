import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/repositories/download_task_repository.dart';
import 'package:venera/core/repositories/favorites_repository.dart';
import 'package:venera/core/repositories/history_repository.dart';
import 'package:venera/core/repositories/local_library_repository.dart';
import 'package:venera/core/repositories/settings_repository.dart';
import 'package:venera/core/repositories/source_repository.dart';

/// Repositories that share the single initialized [AppDatabase].
final class DomainRepositories {
  DomainRepositories(AppDatabase database)
    : settings = SqliteSettingsRepository(database),
      history = SqliteHistoryRepository(database),
      favorites = SqliteFavoritesRepository(database),
      localLibrary = SqliteLocalLibraryRepository(database),
      downloadTasks = SqliteDownloadTaskRepository(database),
      sources = SqliteSourceRepository(database);

  final SettingsRepository settings;
  final HistoryRepository history;
  final FavoritesRepository favorites;
  final LocalLibraryRepository localLibrary;
  final DownloadTaskRepository downloadTasks;
  final SourceRepository sources;
}
