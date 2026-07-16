import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/core/upgrade/rewrite_upgrade_coordinator.dart';

void main() {
  const completeBackupEntries =
      RewriteUpgradeCoordinator.requiredBackupEntryPaths;
  final backupFingerprint = List<String>.filled(64, '0').join();
  late Directory root;
  late Directory data;
  late Directory cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-rewrite-upgrade-');
    data = Directory(p.join(root.path, 'data'))..createSync();
    cache = Directory(p.join(root.path, 'cache'))..createSync();
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  RewriteUpgradeCoordinator coordinator({
    Future<void> Function(String step)? afterStep,
  }) => RewriteUpgradeCoordinator(
    dataDirectory: data,
    cacheDirectory: cache,
    clock: () => DateTime.utc(2026, 7, 16),
    afterStep: afterStep,
  );

  test('fresh installation writes marker and does not block startup', () async {
    final snapshot = await coordinator().inspectAndRecover();

    expect(snapshot.phase, RewriteUpgradePhase.notRequired);
    final marker = File(
      p.join(data.path, RewriteUpgradeCoordinator.markerFileName),
    );
    expect(marker.existsSync(), isTrue);
    expect(jsonDecode(marker.readAsStringSync()), {
      'format': 'venera-rewrite',
      'targetVersion': RewriteUpgradeCoordinator.currentTargetVersion,
      'completedAt': '2026-07-16T00:00:00.000Z',
    });
  });

  test(
    'reset requires external backup and preserves every comic root',
    () async {
      final managedComic = File(p.join(data.path, 'local', 'comic-a', '1.jpg'))
        ..createSync(recursive: true);
      managedComic.writeAsBytesSync([1, 2, 3]);
      final externalRoot = Directory(p.join(root.path, 'external-library'))
        ..createSync();
      final externalComic = File(p.join(externalRoot.path, 'comic-b', '1.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([4, 5, 6]);
      File(
        p.join(data.path, 'local_path'),
      ).writeAsStringSync(externalRoot.path);
      File(p.join(data.path, 'appdata.json')).writeAsStringSync('{}');
      File(p.join(data.path, 'history.db')).writeAsBytesSync([7]);
      File(p.join(data.path, 'downloading_tasks.json')).writeAsStringSync('[]');
      File(p.join(data.path, 'comic_source', 'source.js'))
        ..createSync(recursive: true)
        ..writeAsStringSync('source');
      File(p.join(cache.path, 'image_favorites', 'saved.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([8]);
      File(p.join(cache.path, 'cache', 'disposable.bin'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([9]);
      final indexedAbsoluteComic = Directory(p.join(cache.path, 'linked-comic'))
        ..createSync(recursive: true);
      File(p.join(indexedAbsoluteComic.path, 'page.jpg')).writeAsBytesSync([6]);
      final localIndex = sqlite3.open(p.join(data.path, 'local.db'));
      localIndex.execute('CREATE TABLE comics(directory TEXT NOT NULL);');
      localIndex.execute('INSERT INTO comics(directory) VALUES (?);', [
        indexedAbsoluteComic.path,
      ]);
      localIndex.close();

      final upgrade = coordinator();
      final initial = await upgrade.inspectAndRecover();
      expect(initial.phase, RewriteUpgradePhase.backupRequired);
      final expectedExternalRoot = Platform.isWindows
          ? p.normalize(externalRoot.path).toLowerCase()
          : p.normalize(externalRoot.path);
      expect(initial.preservedLocalRoots, contains(expectedExternalRoot));

      await expectLater(
        upgrade.recordVerifiedBackup(
          savedBackupPath: p.join(data.path, 'unsafe.venera'),
          backupAppVersion: '1.6.34',
          backupCreatedAt: DateTime.utc(2026, 7, 16),
          backupFingerprint: backupFingerprint,
          verifiedEntryPaths: completeBackupEntries,
        ),
        throwsA(isA<FormatException>()),
      );

      final externalBackup = File(p.join(root.path, 'backup.venera'))
        ..writeAsBytesSync([9]);
      final verified = await upgrade.recordVerifiedBackup(
        savedBackupPath: externalBackup.path,
        backupAppVersion: '1.6.34',
        backupCreatedAt: DateTime.utc(2026, 7, 16),
        backupFingerprint: backupFingerprint,
        verifiedEntryPaths: completeBackupEntries,
      );
      expect(verified.phase, RewriteUpgradePhase.backupVerified);

      await expectLater(
        upgrade.resetAfterConfirmation(confirmed: false),
        throwsStateError,
      );
      final completed = await upgrade.resetAfterConfirmation(confirmed: true);

      expect(completed.phase, RewriteUpgradePhase.resetCompleted);
      expect(managedComic.existsSync(), isTrue);
      expect(externalComic.existsSync(), isTrue);
      expect(
        File(p.join(data.path, 'local_path')).readAsStringSync(),
        externalRoot.path,
      );
      expect(File(p.join(data.path, 'appdata.json')).existsSync(), isFalse);
      expect(File(p.join(data.path, 'history.db')).existsSync(), isFalse);
      expect(
        File(p.join(data.path, 'downloading_tasks.json')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(data.path, 'comic_source')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(cache.path, 'image_favorites', 'saved.jpg')).existsSync(),
        isTrue,
      );
      expect(Directory(p.join(cache.path, 'cache')).existsSync(), isFalse);
      expect(indexedAbsoluteComic.existsSync(), isTrue);

      await upgrade.acknowledgeCompletion();
      expect(
        File(
          p.join(data.path, RewriteUpgradeCoordinator.journalFileName),
        ).existsSync(),
        isFalse,
      );
      expect(
        (await upgrade.inspectAndRecover()).phase,
        RewriteUpgradePhase.notRequired,
      );
    },
  );

  test('startup resumes an interrupted confirmed reset idempotently', () async {
    File(p.join(data.path, 'appdata.json')).writeAsStringSync('{}');
    File(p.join(data.path, 'history.db')).writeAsBytesSync([1]);
    final backup = File(p.join(root.path, 'backup.venera'))
      ..writeAsBytesSync([2]);
    var interrupted = false;
    final first = coordinator(
      afterStep: (step) async {
        if (!interrupted && step == 'deleted-data:appdata.json') {
          interrupted = true;
          throw StateError('simulated process stop');
        }
      },
    );
    expect(
      (await first.inspectAndRecover()).phase,
      RewriteUpgradePhase.backupRequired,
    );
    await first.recordVerifiedBackup(
      savedBackupPath: backup.path,
      backupAppVersion: '1.6.34',
      backupCreatedAt: DateTime.utc(2026, 7, 16),
      backupFingerprint: backupFingerprint,
      verifiedEntryPaths: completeBackupEntries,
    );

    await expectLater(
      first.resetAfterConfirmation(confirmed: true),
      throwsStateError,
    );
    expect(File(p.join(data.path, 'history.db')).existsSync(), isTrue);

    final recovered = await coordinator().inspectAndRecover();
    expect(recovered.phase, RewriteUpgradePhase.resetCompleted);
    expect(File(p.join(data.path, 'history.db')).existsSync(), isFalse);
    expect(
      File(
        p.join(data.path, RewriteUpgradeCoordinator.markerFileName),
      ).existsSync(),
      isTrue,
    );
  });

  test(
    'invalid journal artifacts block startup instead of bypassing reset',
    () async {
      File(
        p.join(data.path, RewriteUpgradeCoordinator.journalFileName),
      ).writeAsStringSync('{broken');

      await expectLater(
        coordinator().inspectAndRecover(),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
