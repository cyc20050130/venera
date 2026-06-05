import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  testWidgets('showInputDialog closes after successful confirm', (
    tester,
  ) async {
    await _pumpInputDialogHost(tester, onConfirm: (_) => null);

    await _openDialog(tester);
    expect(find.text('Stable input'), findsOneWidget);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.text('Stable input'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showInputDialog contains sync confirm failures', (tester) async {
    await _pumpInputDialogHost(
      tester,
      onConfirm: (_) => throw StateError('sync failure'),
    );

    await _openDialog(tester);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.text('Stable input'), findsOneWidget);
    expect(find.text('Operation failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showInputDialog contains async confirm failures', (
    tester,
  ) async {
    await _pumpInputDialogHost(
      tester,
      onConfirm: (_) async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('async failure');
      },
    );

    await _openDialog(tester);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.text('Stable input'), findsOneWidget);
    expect(find.text('Operation failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpInputDialogHost(
  WidgetTester tester, {
  required FutureOr<Object?> Function(String) onConfirm,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          return TextButton(
            onPressed: () {
              showInputDialog(
                context: context,
                title: 'Stable input',
                initialValue: 'value',
                confirmText: 'Apply',
                onConfirm: onConfirm,
              );
            },
            child: const Text('open'),
          );
        },
      ),
    ),
  );
}

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
