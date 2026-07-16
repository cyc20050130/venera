import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/providers/app_providers.dart';
import 'package:venera/core/providers/repository_providers.dart';
import 'package:venera/core/repositories/settings_repository.dart';

void main() {
  test('Riverpod exposes one shared repository bundle', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera_domain_repository_provider_',
    );
    final container = ProviderContainer(
      overrides: [
        appDatabasePathProvider.overrideWithValue(
          p.join(directory.path, AppDatabase.fileName),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await directory.delete(recursive: true);
    });

    final bundle = await container.read(domainRepositoriesProvider.future);
    expect(
      await container.read(settingsRepositoryProvider.future),
      same(bundle.settings),
    );
    expect(
      await container.read(historyRepositoryProvider.future),
      same(bundle.history),
    );
    expect(
      await container.read(downloadTaskRepositoryProvider.future),
      same(bundle.downloadTasks),
    );
  });

  test('repository interfaces are independently overrideable', () async {
    final fake = _FakeSettingsRepository();
    final container = ProviderContainer(
      overrides: [settingsRepositoryProvider.overrideWith((ref) async => fake)],
    );
    addTearDown(container.dispose);

    expect(await container.read(settingsRepositoryProvider.future), same(fake));
  });
}

final class _FakeSettingsRepository extends Fake
    implements SettingsRepository {}
