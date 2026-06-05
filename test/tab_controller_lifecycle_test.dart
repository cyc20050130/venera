import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/tab_controller.dart';

void main() {
  testWidgets('replaceOwnedTabController disposes the previous controller', (
    tester,
  ) async {
    late TabController first;
    late TabController second;

    await tester.pumpWidget(
      _TickerHost(
        onReady: (vsync) {
          first = TabController(length: 2, vsync: vsync);
          second = replaceOwnedTabController(
            previous: first,
            length: 3,
            vsync: vsync,
          );
        },
      ),
    );

    expect(second.length, 3);
    expect(() => first.index = 1, throwsA(anything));

    second.dispose();
  });
}

class _TickerHost extends StatefulWidget {
  const _TickerHost({required this.onReady});

  final void Function(TickerProvider vsync) onReady;

  @override
  State<_TickerHost> createState() => _TickerHostState();
}

class _TickerHostState extends State<_TickerHost>
    with TickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    widget.onReady(this);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
