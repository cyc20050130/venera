import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets('Button honors initial loading state before first update', (
    tester,
  ) async {
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Button.filled(
            isLoading: true,
            onPressed: () => taps++,
            child: const Text('Save'),
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.byType(Button));
    await tester.pump();

    expect(taps, 0);
    expect(tester.takeException(), isNull);
  });
}
