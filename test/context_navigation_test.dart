import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/context.dart';

void main() {
  testWidgets('navigation helpers ignore unmounted contexts', (tester) async {
    BuildContext? staleContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            staleContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());

    expect(staleContext!.mounted, isFalse);
    expect(staleContext!.canPop(), isFalse);
    await expectLater(
      staleContext!.to<void>(() => const SizedBox()),
      completion(isNull),
    );
    await expectLater(
      staleContext!.toReplacement<void>(() => const SizedBox()),
      completes,
    );
    expect(tester.takeException(), isNull);
  });
}
