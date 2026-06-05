import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/init.dart';

void main() {
  test('Init can be marked uninitialized and initialized again', () async {
    final target = _InitProbe();

    await target.init();
    await target.ensureInit();
    expect(target.initCount, 1);

    target.resetForTesting();
    final waitAfterReset = target.ensureInit();
    var completed = false;
    unawaited(waitAfterReset.then((_) => completed = true));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    await target.init();
    await waitAfterReset;

    expect(completed, isTrue);
    expect(target.initCount, 2);
  });

  test('Init reset releases waiters from a discarded instance', () async {
    final target = _InitProbe();
    final waiter = target.ensureInit();
    var completed = false;
    unawaited(waiter.then((_) => completed = true));

    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    target.resetForTesting();
    await waiter;

    expect(completed, isTrue);
  });
}

class _InitProbe with Init {
  int initCount = 0;

  @override
  Future<void> doInit() async {
    initCount++;
  }

  void resetForTesting() {
    markUninitialized();
  }
}
