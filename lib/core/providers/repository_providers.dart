import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:venera/core/providers/app_providers.dart';
import 'package:venera/core/repositories/domain_repositories.dart';
import 'package:venera/core/repositories/download_task_repository.dart';
import 'package:venera/core/repositories/favorites_repository.dart';
import 'package:venera/core/repositories/history_repository.dart';
import 'package:venera/core/repositories/local_library_repository.dart';
import 'package:venera/core/repositories/settings_repository.dart';
import 'package:venera/core/repositories/source_repository.dart';

final domainRepositoriesProvider = FutureProvider<DomainRepositories>((
  ref,
) async {
  final database = await ref.watch(appDatabaseProvider.future);
  return DomainRepositories(database);
});

final settingsRepositoryProvider = FutureProvider<SettingsRepository>(
  (ref) async => (await ref.watch(domainRepositoriesProvider.future)).settings,
);

final historyRepositoryProvider = FutureProvider<HistoryRepository>(
  (ref) async => (await ref.watch(domainRepositoriesProvider.future)).history,
);

final favoritesRepositoryProvider = FutureProvider<FavoritesRepository>(
  (ref) async => (await ref.watch(domainRepositoriesProvider.future)).favorites,
);

final localLibraryRepositoryProvider = FutureProvider<LocalLibraryRepository>(
  (ref) async =>
      (await ref.watch(domainRepositoriesProvider.future)).localLibrary,
);

final downloadTaskRepositoryProvider = FutureProvider<DownloadTaskRepository>(
  (ref) async =>
      (await ref.watch(domainRepositoriesProvider.future)).downloadTasks,
);

final sourceRepositoryProvider = FutureProvider<SourceRepository>(
  (ref) async => (await ref.watch(domainRepositoriesProvider.future)).sources,
);
