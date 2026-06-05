import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await AppTranslation.init();
  });

  testWidgets('SearchBarController detaches disposed AppSearchBar state', (
    tester,
  ) async {
    final controller = SearchBarController(currentText: 'seed');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppSearchBar(controller: controller)),
      ),
    );

    await tester.enterText(find.byType(TextField), 'typed');
    expect(controller.text, 'typed');

    await tester.pumpWidget(const SizedBox.shrink());
    expect(controller.text, 'typed');

    controller.text = 'after-dispose';
    expect(controller.text, 'after-dispose');
  });
}
