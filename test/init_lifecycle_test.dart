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

  test('concurrent init calls share one initialization', () async {
    final gate = Completer<void>();
    final target = _InitProbe(gate: gate.future);

    final first = target.init();
    final second = target.init();
    await Future<void>.delayed(Duration.zero);

    expect(target.initCount, 1);
    gate.complete();
    await Future.wait([first, second]);
    expect(target.initCount, 1);
  });

  test('failed initialization rejects waiters and can retry', () async {
    final target = _InitProbe(failuresBeforeSuccess: 1);
    final waiter = target.ensureInit();

    await expectLater(target.init(), throwsStateError);
    await expectLater(waiter, throwsStateError);
    await target.init();

    expect(target.initCount, 2);
    await target.ensureInit();
  });
}

class _InitProbe with Init {
  _InitProbe({this.gate, this.failuresBeforeSuccess = 0});

  final Future<void>? gate;
  int failuresBeforeSuccess;
  int initCount = 0;

  @override
  Future<void> doInit() async {
    initCount++;
    await gate;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw StateError('init failed');
    }
  }

  void resetForTesting() {
    markUninitialized();
  }
}
