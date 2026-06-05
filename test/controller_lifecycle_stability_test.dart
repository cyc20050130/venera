import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/utils/volume.dart';

void main() {
  testWidgets('FlyoutController ignores calls after its Flyout is disposed', (
    tester,
  ) async {
    final controller = FlyoutController();

    await tester.pumpWidget(
      MaterialApp(
        home: Flyout(
          controller: controller,
          flyoutBuilder: (_) => const SizedBox(key: Key('flyout-content')),
          child: const SizedBox(width: 24, height: 24),
        ),
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());

    expect(controller.show, returnsNormally);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GlobalState does not return unmounted states', (tester) async {
    await tester.pumpWidget(const _GlobalStateProbe());

    expect(GlobalState.findOrNull<_GlobalStateProbeState>('probe'), isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(GlobalState.findOrNull<_GlobalStateProbeState>('probe'), isNull);
  });

  testWidgets('AppScrollBar rebinds when its ScrollController changes', (
    tester,
  ) async {
    final first = _InspectableScrollController();
    final second = _InspectableScrollController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(
      MaterialApp(home: _AppScrollBarProbe(controller: first)),
    );

    expect(first.debugHasListeners, isTrue);
    expect(second.debugHasListeners, isFalse);

    await tester.pumpWidget(
      MaterialApp(home: _AppScrollBarProbe(controller: second)),
    );

    expect(first.debugHasListeners, isFalse);
    expect(second.debugHasListeners, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(second.debugHasListeners, isFalse);
  });

  testWidgets('AppScrollBar ignores queued updates after dispose', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: _AppScrollBarProbe(controller: controller)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('NaviPane main view handler ignores calls after dispose', (
    tester,
  ) async {
    final naviKey = GlobalKey<NaviPaneState>();
    final navigatorKey = GlobalKey<NavigatorState>();
    final observer = NaviObserver();

    await tester.pumpWidget(
      MaterialApp(
        home: NaviPane(
          key: naviKey,
          observer: observer,
          navigatorKey: navigatorKey,
          paneItems: [
            PaneItemEntry(
              label: 'Home',
              icon: Icons.home_outlined,
              activeIcon: Icons.home,
            ),
          ],
          paneActions: const [],
          pageBuilder: (_) => const Text('page'),
        ),
      ),
    );
    await tester.pump();

    final handler = naviKey.currentState!.mainViewUpdateHandler;
    expect(handler, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    handler?.call();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  test('VolumeListener ignores missing callbacks', () {
    final listener = VolumeListener();

    expect(() => listener.onEvent(1), returnsNormally);
    expect(() => listener.onEvent(2), returnsNormally);
  });

  test('VolumeListener dispatches available callbacks', () {
    var up = 0;
    var down = 0;
    final listener = VolumeListener(onUp: () => up++, onDown: () => down++);

    listener.onEvent(1);
    listener.onEvent(2);
    listener.onEvent(3);

    expect(up, 1);
    expect(down, 1);
  });

  test('VolumeListener handles platform stream errors', () async {
    final controller = StreamController<dynamic>();
    final listener = VolumeListener();

    listener.listenTo(controller.stream);
    controller.addError(StateError('bad volume event'), StackTrace.current);
    await Future<void>.delayed(Duration.zero);

    listener.cancel();
    await controller.close();
  });

  test('NaviObserver survives listener removal during notification', () {
    final observer = NaviObserver();
    var firstCalls = 0;
    var secondCalls = 0;

    void first() {
      firstCalls++;
      observer.removeListener(first);
    }

    void second() {
      secondCalls++;
    }

    observer.addListener(first);
    observer.addListener(second);

    observer.notifyListeners();
    observer.notifyListeners();

    expect(firstCalls, 1);
    expect(secondCalls, 2);
  });

  test('NaviObserver removes the popped route instead of the last route', () {
    final observer = NaviObserver();
    final first = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    final second = MaterialPageRoute<void>(builder: (_) => const SizedBox());

    observer.didPush(first, null);
    observer.didPush(second, first);
    observer.didPop(first, null);

    expect(observer.routes, [second]);
  });
}

class _GlobalStateProbe extends StatefulWidget {
  const _GlobalStateProbe();

  @override
  State<_GlobalStateProbe> createState() => _GlobalStateProbeState();
}

class _GlobalStateProbeState extends AutomaticGlobalState<_GlobalStateProbe> {
  @override
  Object? get key => 'probe';

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _InspectableScrollController extends ScrollController {
  bool get debugHasListeners => hasListeners;
}

class _AppScrollBarProbe extends StatelessWidget {
  const _AppScrollBarProbe({required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return AppScrollBar(
      controller: controller,
      child: ListView(
        controller: controller,
        children: const [SizedBox(height: 1200)],
      ),
    );
  }
}
