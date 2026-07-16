import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/design_system/app_design_system.dart';

void main() {
  testWidgets('adaptive navigation uses bottom bar on compact screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveNavigationScaffold(
          selectedIndex: 0,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), label: 'A'),
            NavigationDestination(icon: Icon(Icons.star_outline), label: 'B'),
          ],
          onDestinationSelected: (_) {},
          body: const SizedBox(),
        ),
      ),
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('adaptive navigation uses an extended rail on wide screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveNavigationScaffold(
          selectedIndex: 0,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), label: 'A'),
            NavigationDestination(icon: Icon(Icons.star_outline), label: 'B'),
          ],
          onDestinationSelected: (_) {},
          body: const SizedBox(),
        ),
      ),
    );

    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.extended, isTrue);
  });

  test('theme factory enables Material 3', () {
    final theme = AppTheme.build(
      brightness: Brightness.light,
      primary: Colors.blue,
    );
    expect(theme.useMaterial3, isTrue);
    expect(theme.cardTheme.elevation, 0);
  });
}
