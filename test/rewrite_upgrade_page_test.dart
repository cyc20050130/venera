import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/rewrite_upgrade_page.dart';

void main() {
  Widget buildPage({
    required RewriteUpgradePageState state,
    Future<void> Function()? onExport,
    Future<void> Function()? onReset,
    Future<void> Function()? onRetry,
  }) {
    return MaterialApp(
      home: RewriteUpgradePage(
        state: state,
        onExportBackup: onExport ?? () async {},
        onReset: onReset ?? () async {},
        onRetry: onRetry ?? () async {},
      ),
    );
  }

  testWidgets('backup is the only available action before verification', (
    tester,
  ) async {
    var exportCalls = 0;
    await tester.pumpWidget(
      buildPage(
        state: const RewriteUpgradePageState(
          phase: RewriteUpgradeUiPhase.backupRequired,
        ),
        onExport: () async => exportCalls++,
      ),
    );

    expect(find.byKey(const ValueKey('rewrite-upgrade-page')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('rewrite-upgrade-export')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('rewrite-upgrade-reset')), findsNothing);

    final exportButton = find.byKey(const ValueKey('rewrite-upgrade-export'));
    await tester.ensureVisible(exportButton);
    await tester.tap(exportButton);
    await tester.pump();
    expect(exportCalls, 1);
  });

  testWidgets('verified backup still requires explicit reset confirmation', (
    tester,
  ) async {
    var resetCalls = 0;
    await tester.pumpWidget(
      buildPage(
        state: const RewriteUpgradePageState(
          phase: RewriteUpgradeUiPhase.backupReady,
          backupPath: r'D:\Backups\data.venera',
        ),
        onReset: () async => resetCalls++,
      ),
    );

    final resetButton = find.byKey(const ValueKey('rewrite-upgrade-reset'));
    await tester.ensureVisible(resetButton);
    await tester.tap(resetButton);
    await tester.pumpAndSettle();

    final confirm = tester.widget<FilledButton>(
      find.byKey(const ValueKey('rewrite-upgrade-confirm-reset')),
    );
    expect(confirm.onPressed, isNull);
    expect(resetCalls, 0);

    await tester.tap(find.byKey(const ValueKey('rewrite-upgrade-acknowledge')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('rewrite-upgrade-confirm-reset')),
    );
    await tester.pumpAndSettle();

    expect(resetCalls, 1);
  });

  testWidgets('failed operation exposes its error and a retry action', (
    tester,
  ) async {
    var retryCalls = 0;
    await tester.pumpWidget(
      buildPage(
        state: const RewriteUpgradePageState(
          phase: RewriteUpgradeUiPhase.failed,
          errorMessage: 'Backup validation failed',
        ),
        onRetry: () async => retryCalls++,
      ),
    );

    expect(find.byKey(const ValueKey('rewrite-upgrade-error')), findsOneWidget);
    expect(find.text('Backup validation failed'), findsOneWidget);

    final retryButton = find.byKey(const ValueKey('rewrite-upgrade-retry'));
    await tester.ensureVisible(retryButton);
    await tester.tap(retryButton);
    await tester.pump();
    expect(retryCalls, 1);
  });

  testWidgets('destructive work has progress feedback and no action button', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildPage(
        state: const RewriteUpgradePageState(
          phase: RewriteUpgradeUiPhase.resetting,
        ),
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('rewrite-upgrade-export')), findsNothing);
    expect(find.byKey(const ValueKey('rewrite-upgrade-reset')), findsNothing);
  });
}
