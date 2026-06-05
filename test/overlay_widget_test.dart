import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/overlay_entry.dart';

void main() {
  testWidgets('removeAndDisposeOverlayEntry removes and disposes owner entry', (
    tester,
  ) async {
    late OverlayEntry ownedEntry;

    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (context) {
                return TextButton(
                  onPressed: () {
                    ownedEntry = OverlayEntry(
                      builder: (context) => const Text('owned-overlay'),
                    );
                    Overlay.of(context).insert(ownedEntry);
                  },
                  child: const Text('insert-overlay'),
                );
              },
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('insert-overlay'));
    await tester.pump();
    expect(find.text('owned-overlay'), findsOneWidget);

    removeAndDisposeOverlayEntry(ownedEntry);
    await tester.pump();

    expect(find.text('owned-overlay'), findsNothing);
    expect(() => ownedEntry.addListener(() {}), throwsA(isA<AssertionError>()));
  });

  testWidgets('OverlayWidget removes toast entries when disposed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OverlayWidget(
          Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showToast(
                    message: 'toast-message',
                    context: context,
                    seconds: 1,
                  );
                },
                child: const Text('show-toast'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('show-toast'));
    await tester.pump();
    expect(find.text('toast-message'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(find.text('toast-message'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('OverlayWidget root entry rebuilds when child changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: OverlayWidget(Text('overlay-child-a'))),
    );
    expect(find.text('overlay-child-a'), findsOneWidget);
    expect(find.text('overlay-child-b'), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(home: OverlayWidget(Text('overlay-child-b'))),
    );
    await tester.pump();

    expect(find.text('overlay-child-a'), findsNothing);
    expect(find.text('overlay-child-b'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OverlayWidget disposes toast entries after timeout', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OverlayWidget(
          Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showToast(
                    message: 'timeout-toast',
                    context: context,
                    seconds: 1,
                  );
                },
                child: const Text('show-timeout-toast'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('show-timeout-toast'));
    await tester.pump();
    expect(find.text('timeout-toast'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('timeout-toast'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showToast is a no-op without OverlayWidget host', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                showToast(message: 'missing-host-toast', context: context);
              },
              child: const Text('show-without-host'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('show-without-host'));
    await tester.pump();

    expect(find.text('missing-host-toast'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
