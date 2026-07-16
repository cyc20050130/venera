import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/core/upgrade/rewrite_upgrade_coordinator.dart';
import 'package:venera/foundation/bootstrap.dart';
import 'package:venera/foundation/rewrite_upgrade.dart';
import 'package:venera/utils/backup_v2.dart';

void main() {
  late Directory root;
  late Directory data;
  late Directory cache;
  late RewriteUpgradeCoordinator coordinator;
  late _TestBootstrapController bootstrap;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-rewrite-flow-');
    data = Directory(p.join(root.path, 'data'))..createSync();
    cache = Directory(p.join(root.path, 'cache'))..createSync();
    coordinator = RewriteUpgradeCoordinator(
      dataDirectory: data,
      cacheDirectory: cache,
    );
    bootstrap = _TestBootstrapController(coordinator);
    bootstrap.applyRewriteUpgradeSnapshot(
      RewriteUpgradeSnapshot(
        phase: RewriteUpgradePhase.backupRequired,
        preservedLocalRoots: [p.join(data.path, 'local')],
      ),
    );
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('complete backup advances through reset and releases startup', () async {
    final exported = File(p.join(root.path, 'temporary.venera'))
      ..writeAsBytesSync([1, 2, 3]);
    final savedPath = p.join(root.path, 'external.venera');
    final flow = RewriteUpgradeFlowController(
      bootstrap: bootstrap,
      exportBackup: () async => exported,
      validateBackup: (_) async => _manifest(complete: true),
      saveBackup: (file) async {
        await file.copy(savedPath);
        return savedPath;
      },
      completionDisplayDuration: Duration.zero,
    );
    addTearDown(flow.dispose);

    await flow.exportAndVerifyBackup();

    expect(flow.errorMessage, isNull);
    expect(flow.snapshot?.phase, RewriteUpgradePhase.backupVerified);
    expect(
      flow.snapshot?.savedBackupPath,
      Platform.isWindows
          ? p.normalize(savedPath).toLowerCase()
          : p.normalize(savedPath),
    );

    await flow.resetAfterConfirmation();

    expect(flow.errorMessage, isNull);
    expect(flow.snapshot?.phase, RewriteUpgradePhase.notRequired);
    expect(
      File(
        p.join(data.path, RewriteUpgradeCoordinator.markerFileName),
      ).existsSync(),
      isTrue,
    );
  });

  test(
    'deleted external backup blocks reset and preserves legacy data',
    () async {
      final legacy = File(p.join(data.path, 'history.db'))
        ..writeAsBytesSync([7, 8, 9]);
      final exported = File(p.join(root.path, 'temporary.venera'))
        ..writeAsBytesSync([1, 2, 3]);
      final savedPath = p.join(root.path, 'external.venera');
      final flow = RewriteUpgradeFlowController(
        bootstrap: bootstrap,
        exportBackup: () async => exported,
        validateBackup: (_) async => _manifest(complete: true),
        saveBackup: (file) async {
          await file.copy(savedPath);
          return savedPath;
        },
        completionDisplayDuration: Duration.zero,
      );
      addTearDown(flow.dispose);

      await flow.exportAndVerifyBackup();
      await File(savedPath).delete();
      await flow.resetAfterConfirmation();

      expect(flow.snapshot?.phase, RewriteUpgradePhase.backupVerified);
      expect(flow.errorMessage, contains('no longer exists'));
      expect(legacy.existsSync(), isTrue);
    },
  );

  test('incomplete backup cannot unlock the destructive action', () async {
    final exported = File(p.join(root.path, 'temporary.venera'))
      ..writeAsBytesSync([1]);
    final flow = RewriteUpgradeFlowController(
      bootstrap: bootstrap,
      exportBackup: () async => exported,
      validateBackup: (_) async => _manifest(complete: false),
      saveBackup: (_) async => p.join(root.path, 'external.venera'),
      completionDisplayDuration: Duration.zero,
    );
    addTearDown(flow.dispose);

    await flow.exportAndVerifyBackup();

    expect(flow.snapshot?.phase, RewriteUpgradePhase.backupRequired);
    expect(flow.failedAction, RewriteUpgradeFailedAction.exportBackup);
    expect(flow.errorMessage, contains('not a complete V2 backup'));
  });
}

BackupManifestV2 _manifest({required bool complete}) {
  final paths = RewriteUpgradeCoordinator.requiredBackupEntryPaths.toList()
    ..sort();
  if (!complete) paths.removeLast();
  return BackupManifestV2(
    createdAt: DateTime.utc(2026, 7, 16),
    appVersion: '1.6.34',
    isFullBackup: true,
    entries: paths
        .map(
          (path) => BackupEntryV2(
            path: path,
            length: 0,
            sha256: List.filled(64, '0').join(),
            kind: 'test',
          ),
        )
        .toList(growable: false),
  );
}

final class _TestBootstrapController extends BootstrapController {
  _TestBootstrapController(this.coordinator)
    : super(startupInteractionProtectionWindow: Duration.zero);

  final RewriteUpgradeCoordinator coordinator;

  @override
  RewriteUpgradeCoordinator get rewriteUpgradeCoordinator => coordinator;
}
