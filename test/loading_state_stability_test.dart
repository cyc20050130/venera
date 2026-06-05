import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  testWidgets(
    'LoadingState does not setState after dispose while onDataLoaded awaits',
    (tester) async {
      final onDataLoadedStarted = Completer<void>();
      final allowOnDataLoadedToFinish = Completer<void>();

      await tester.pumpWidget(
        MaterialApp(
          home: _LoadingStateProbe(
            onDataLoadedStarted: onDataLoadedStarted,
            allowOnDataLoadedToFinish: allowOnDataLoadedToFinish.future,
          ),
        ),
      );

      await onDataLoadedStarted.future;
      await tester.pumpWidget(const SizedBox.shrink());
      allowOnDataLoadedToFinish.complete();
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('LoadingState stops retrying after dispose', (tester) async {
    final firstLoadStarted = Completer<void>();
    var loadCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: _RetryLoadingStateProbe(
          onLoad: () {
            loadCount++;
            if (loadCount == 1) {
              firstLoadStarted.complete();
            }
          },
        ),
      ),
    );

    await firstLoadStarted.future;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 250));

    expect(loadCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showLoadingDialog reports a single close notification', (
    tester,
  ) async {
    late LoadingDialogController controller;
    var closeCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                controller = showLoadingDialog(
                  context,
                  onClosed: () => closeCount++,
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    controller.close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    controller.close();
    await tester.pump();

    expect(closeCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showLoadingDialog normalizes invalid progress values', (
    tester,
  ) async {
    late LoadingDialogController controller;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                controller = showLoadingDialog(context, withProgress: true);
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    controller.setProgress(double.nan);
    await tester.pump();
    controller.setProgress(double.infinity);
    await tester.pump();
    controller.setProgress(-1);
    await tester.pump();
    controller.setProgress(2);
    await tester.pump();
    controller.close();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  test('normalizeLoadingMaxPage accepts numeric source values', () {
    expect(normalizeLoadingMaxPage(3), 3);
    expect(normalizeLoadingMaxPage(3.7), 3);
    expect(normalizeLoadingMaxPage('4'), 4);
    expect(normalizeLoadingMaxPage('bad'), isNull);
  });

  testWidgets('MultiPageLoadingState clears max page when reset', (
    tester,
  ) async {
    final key = GlobalKey<_MultiPageProbeState>();

    await tester.pumpWidget(MaterialApp(home: _MultiPageProbe(key: key)));
    await tester.pumpAndSettle();

    expect(find.text('old-1'), findsOneWidget);
    expect(key.currentState!.haveNextPage, isFalse);

    key.currentState!.resetToNewData();
    await tester.pumpAndSettle();

    expect(find.text('new-1'), findsOneWidget);
    expect(key.currentState!.haveNextPage, isTrue);

    key.currentState!.nextPage();
    await tester.pumpAndSettle();

    expect(find.text('new-2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _LoadingStateProbe extends StatefulWidget {
  const _LoadingStateProbe({
    required this.onDataLoadedStarted,
    required this.allowOnDataLoadedToFinish,
  });

  final Completer<void> onDataLoadedStarted;
  final Future<void> allowOnDataLoadedToFinish;

  @override
  State<_LoadingStateProbe> createState() => _LoadingStateProbeState();
}

class _LoadingStateProbeState extends LoadingState<_LoadingStateProbe, String> {
  @override
  Future<Res<String>> loadData() async => const Res('loaded');

  @override
  Future<void> onDataLoaded() async {
    widget.onDataLoadedStarted.complete();
    await widget.allowOnDataLoadedToFinish;
  }

  @override
  Widget buildContent(BuildContext context, String data) {
    return Text(data, textDirection: TextDirection.ltr);
  }
}

class _RetryLoadingStateProbe extends StatefulWidget {
  const _RetryLoadingStateProbe({required this.onLoad});

  final VoidCallback onLoad;

  @override
  State<_RetryLoadingStateProbe> createState() =>
      _RetryLoadingStateProbeState();
}

class _RetryLoadingStateProbeState
    extends LoadingState<_RetryLoadingStateProbe, String> {
  @override
  Future<Res<String>> loadData() async {
    widget.onLoad();
    return const Res.error('failed');
  }

  @override
  Widget buildContent(BuildContext context, String data) {
    return Text(data, textDirection: TextDirection.ltr);
  }
}

class _MultiPageProbe extends StatefulWidget {
  const _MultiPageProbe({super.key});

  @override
  State<_MultiPageProbe> createState() => _MultiPageProbeState();
}

class _MultiPageProbeState
    extends MultiPageLoadingState<_MultiPageProbe, String> {
  bool useNewData = false;

  void resetToNewData() {
    useNewData = true;
    reset();
  }

  @override
  Future<Res<List<String>>> loadData(int page) async {
    if (!useNewData) {
      return Res(['old-$page'], subData: 1);
    }
    return Res(['new-$page'], subData: '3');
  }

  @override
  Widget buildContent(BuildContext context, List<String> data) {
    return Column(
      textDirection: TextDirection.ltr,
      children: [for (final item in data) Text(item)],
    );
  }
}
