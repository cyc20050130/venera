import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/js_pool.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/perf_trace.dart';

void main() {
  setUp(() => PerfTrace.debugConfigure(isEnabled: false));
  tearDown(PerfTrace.debugReset);

  test('init returns after the first worker is ready', () async {
    final workers = <_FakeJsPoolWorker>[];
    final pool = JSPool.forTesting(
      maxInstances: 2,
      loadJsInit: () async => Uint8List.fromList([1, 2, 3]),
      createWorker: (_) {
        final worker = _FakeJsPoolWorker();
        workers.add(worker);
        return worker;
      },
    );

    var initCompleted = false;
    final initFuture = pool.init();
    unawaited(initFuture.then((_) => initCompleted = true));
    await _waitUntil(() => workers.length == 1);
    expect(initCompleted, isFalse);

    workers.first.completeReady();
    await initFuture;
    expect(initCompleted, isTrue);

    await _waitUntil(() => workers.length == 2);
    expect(workers[1].isReady, isFalse);
    workers[1].completeReady();
    await _flushAsyncEvents();
  });

  test('concurrent init calls share the first worker startup', () async {
    var loadCount = 0;
    final workers = <_FakeJsPoolWorker>[];
    final pool = JSPool.forTesting(
      maxInstances: 1,
      loadJsInit: () async {
        loadCount++;
        return Uint8List(0);
      },
      createWorker: (_) {
        final worker = _FakeJsPoolWorker();
        workers.add(worker);
        return worker;
      },
    );

    final first = pool.init();
    final second = pool.init();
    await _waitUntil(() => workers.length == 1);
    workers.single.completeReady();
    await Future.wait([first, second]);

    expect(loadCount, 1);
    expect(workers, hasLength(1));
  });

  test(
    'background warmup failure does not reject work and can retry',
    () async {
      final wasLogMuted = Log.isMuted;
      Log.isMuted = true;
      addTearDown(() => Log.isMuted = wasLogMuted);

      final workers = <_FakeJsPoolWorker>[];
      final pool = JSPool.forTesting(
        maxInstances: 2,
        loadJsInit: () async => Uint8List(0),
        createWorker: (_) {
          final worker = _FakeJsPoolWorker(result: 42);
          workers.add(worker);
          return worker;
        },
      );

      final initFuture = pool.init();
      await _waitUntil(() => workers.length == 1);
      workers.first.completeReady();
      await initFuture;

      await _waitUntil(() => workers.length == 2);
      workers[1].completeReadyError(StateError('warmup failed'));
      await _waitUntil(() => workers[1].isClosed);
      await _flushAsyncEvents();

      expect(await pool.execute('(value) => value', [42]), 42);
      await _waitUntil(() => workers.length == 3);
      workers[2].completeReady();
      await _flushAsyncEvents();
    },
  );

  test('execute replaces a closed worker', () async {
    final workers = <_FakeJsPoolWorker>[];
    final pool = JSPool.forTesting(
      maxInstances: 1,
      loadJsInit: () async => Uint8List(0),
      createWorker: (_) {
        final worker = _FakeJsPoolWorker(result: workers.length + 1);
        workers.add(worker);
        return worker;
      },
    );

    final initFuture = pool.init();
    await _waitUntil(() => workers.length == 1);
    workers.first.completeReady();
    await initFuture;
    workers.first.close();

    final resultFuture = pool.execute('() => 2', const []);
    await _waitUntil(() => workers.length == 2);
    workers[1].completeReady();

    expect(await resultFuture, 2);
    expect(workers.first.executeCount, 0);
    expect(workers[1].executeCount, 1);
  });

  test(
    'execute selects the ready worker with the least pending work',
    () async {
      final workers = <_FakeJsPoolWorker>[];
      final pool = JSPool.forTesting(
        maxInstances: 2,
        loadJsInit: () async => Uint8List(0),
        createWorker: (_) {
          final worker = _FakeJsPoolWorker(result: workers.length + 1);
          workers.add(worker);
          return worker;
        },
      );

      final initFuture = pool.init();
      await _waitUntil(() => workers.length == 1);
      workers.first.completeReady();
      await initFuture;
      await _waitUntil(() => workers.length == 2);
      workers[1].completeReady();
      await _flushAsyncEvents();
      workers.first.pendingTasks = 3;

      expect(await pool.execute('() => 2', const []), 2);
      expect(workers.first.executeCount, 0);
      expect(workers[1].executeCount, 1);
    },
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for asynchronous JS pool state');
}

Future<void> _flushAsyncEvents() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeJsPoolWorker implements JsPoolWorker {
  _FakeJsPoolWorker({this.result});

  final Object? result;
  final Completer<void> _ready = Completer<void>();

  @override
  int pendingTasks = 0;

  @override
  bool isClosed = false;

  int executeCount = 0;

  bool get isReady => _ready.isCompleted && !isClosed;

  @override
  Future<void> get ready => _ready.future;

  void completeReady() {
    _ready.complete();
  }

  void completeReadyError(Object error) {
    _ready.completeError(error);
  }

  @override
  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    if (isClosed) {
      throw StateError('worker closed');
    }
    executeCount++;
    return result;
  }

  @override
  void close() {
    isClosed = true;
  }
}
