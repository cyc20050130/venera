import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/perf_trace.dart';

typedef JsPoolWorkerFactory = JsPoolWorker Function(Uint8List jsInit);
typedef JsPoolInitLoader = Future<Uint8List> Function();

abstract interface class JsPoolWorker {
  int get pendingTasks;

  bool get isClosed;

  Future<void> get ready;

  Future<dynamic> execute(String jsFunction, List<dynamic> args);

  void close();
}

class JSPool {
  static const int _defaultMaxInstances = 4;

  final int _maxInstances;
  final JsPoolInitLoader _loadJsInit;
  final JsPoolWorkerFactory _createWorker;
  final List<JsPoolWorker> _instances = [];

  Future<void>? _initFuture;
  Future<void>? _warmupFuture;
  Future<Uint8List>? _jsInitFuture;
  int _startingInstances = 0;

  static final JSPool _singleton = JSPool._internal(
    maxInstances: _defaultMaxInstances,
    loadJsInit: _loadBundledJsInit,
    createWorker: IsolateJsEngine.new,
  );

  factory JSPool() {
    return _singleton;
  }

  JSPool._internal({
    required int maxInstances,
    required JsPoolInitLoader loadJsInit,
    required JsPoolWorkerFactory createWorker,
  }) : _maxInstances = maxInstances,
       _loadJsInit = loadJsInit,
       _createWorker = createWorker;

  @visibleForTesting
  factory JSPool.forTesting({
    required int maxInstances,
    required JsPoolInitLoader loadJsInit,
    required JsPoolWorkerFactory createWorker,
  }) {
    if (maxInstances <= 0) {
      throw ArgumentError.value(
        maxInstances,
        'maxInstances',
        'Must be greater than zero.',
      );
    }
    return JSPool._internal(
      maxInstances: maxInstances,
      loadJsInit: loadJsInit,
      createWorker: createWorker,
    );
  }

  static Future<Uint8List> _loadBundledJsInit() async {
    final data = await rootBundle.load('assets/init.js');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<void> init() async {
    _removeClosedInstances();
    if (_instances.isNotEmpty) {
      _scheduleWarmup();
      return;
    }

    final pending = _initFuture;
    if (pending != null) {
      return pending;
    }
    late final Future<void> operation;
    operation = _init();
    _initFuture = operation;
    try {
      await operation;
    } finally {
      if (identical(_initFuture, operation)) {
        _initFuture = null;
      }
    }
  }

  Future<void> _init() async {
    final span = PerfTrace.start(
      'js_pool_first_ready',
      component: 'JSPool',
      attributes: <String, Object?>{'targetWorkers': _maxInstances},
    );
    try {
      final jsInit = await _loadJsInitOnce();
      _removeClosedInstances();
      if (_instances.isEmpty) {
        final instance = await _startWorker(jsInit);
        if (_instances.length < _maxInstances && !instance.isClosed) {
          _instances.add(instance);
        } else {
          instance.close();
        }
      }

      if (_instances.isEmpty) {
        throw StateError('No healthy JS isolate is available');
      }
      span.finish(
        attributes: <String, Object?>{'readyWorkers': _instances.length},
      );
      _scheduleWarmup();
    } catch (error) {
      span.finish(
        outcome: PerfTraceOutcome.failure,
        attributes: <String, Object?>{'errorType': error.runtimeType},
      );
      rethrow;
    }
  }

  Future<Uint8List> _loadJsInitOnce() async {
    final pending = _jsInitFuture;
    if (pending != null) {
      return pending;
    }

    late final Future<Uint8List> operation;
    operation = _loadJsInit();
    _jsInitFuture = operation;
    try {
      return await operation;
    } catch (_) {
      if (identical(_jsInitFuture, operation)) {
        _jsInitFuture = null;
      }
      rethrow;
    }
  }

  Future<JsPoolWorker> _startWorker(Uint8List jsInit) async {
    JsPoolWorker? instance;
    _startingInstances++;
    try {
      instance = _createWorker(jsInit);
      await instance.ready;
      if (instance.isClosed) {
        throw StateError('JS isolate closed during initialization');
      }
      return instance;
    } catch (_) {
      instance?.close();
      rethrow;
    } finally {
      _startingInstances--;
    }
  }

  void _scheduleWarmup() {
    _removeClosedInstances();
    if (_warmupFuture != null ||
        _instances.length + _startingInstances >= _maxInstances) {
      return;
    }

    // Let the first waiting task use the ready worker before starting the
    // remaining QuickJS runtimes, which can be CPU and memory intensive.
    late final Future<void> operation;
    operation = Future<void>.delayed(Duration.zero, _warmRemainingInstances);
    _warmupFuture = operation;
    unawaited(
      operation
          .catchError((Object error, StackTrace stackTrace) {
            Log.error(
              'JSPool',
              'Failed to warm up a JS isolate: $error',
              stackTrace,
            );
          })
          .whenComplete(() {
            if (identical(_warmupFuture, operation)) {
              _warmupFuture = null;
            }
          }),
    );
  }

  Future<void> _warmRemainingInstances() async {
    final span = PerfTrace.start(
      'js_pool_background_warmup',
      component: 'JSPool',
      attributes: <String, Object?>{
        'readyWorkersAtStart': _instances.length,
        'targetWorkers': _maxInstances,
      },
    );
    try {
      final jsInit = await _loadJsInitOnce();
      while (true) {
        _removeClosedInstances();
        if (_instances.length + _startingInstances >= _maxInstances) {
          span.finish(
            attributes: <String, Object?>{'readyWorkers': _instances.length},
          );
          return;
        }

        final instance = await _startWorker(jsInit);
        if (_instances.length < _maxInstances && !instance.isClosed) {
          _instances.add(instance);
        } else {
          instance.close();
        }
      }
    } catch (error) {
      span.finish(
        outcome: PerfTraceOutcome.failure,
        attributes: <String, Object?>{
          'errorType': error.runtimeType,
          'readyWorkers': _instances.length,
        },
      );
      rethrow;
    }
  }

  void _removeClosedInstances() {
    _instances.removeWhere((instance) => instance.isClosed);
  }

  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      await init();
      _removeClosedInstances();
      if (_instances.isEmpty) {
        continue;
      }
      var selectedInstance = _instances[0];
      for (var instance in _instances) {
        if (instance.pendingTasks < selectedInstance.pendingTasks) {
          selectedInstance = instance;
        }
      }
      try {
        return await selectedInstance.execute(jsFunction, args);
      } catch (_) {
        if (!selectedInstance.isClosed) {
          rethrow;
        }
        _instances.remove(selectedInstance);
      }
    }
    throw StateError('No healthy JS isolate is available');
  }
}

class _IsolateJsEngineInitParam {
  final SendPort sendPort;

  final Uint8List jsInit;

  _IsolateJsEngineInitParam(this.sendPort, this.jsInit);
}

class IsolateJsEngine implements JsPoolWorker {
  Isolate? _isolate;

  SendPort? _sendPort;
  ReceivePort? _receivePort;

  int _counter = 0;
  final Map<int, Completer<dynamic>> _tasks = {};

  bool _isClosed = false;

  final Completer<void> _ready = Completer<void>();

  @override
  int get pendingTasks => _tasks.length;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> get ready => _ready.future;

  IsolateJsEngine(Uint8List jsInit) {
    _receivePort = ReceivePort();
    _receivePort!.listen(_onMessage);
    unawaited(_spawn(jsInit));
  }

  Future<void> _spawn(Uint8List jsInit) async {
    try {
      final receivePort = _receivePort;
      if (receivePort == null) {
        return;
      }
      final isolate = await Isolate.spawn(
        _run,
        _IsolateJsEngineInitParam(receivePort.sendPort, jsInit),
        onError: receivePort.sendPort,
        onExit: receivePort.sendPort,
      );
      if (_isClosed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
    } catch (e, s) {
      _onMessage(Exception("Failed to spawn JS isolate: $e\n$s"));
    }
  }

  void _onMessage(dynamic message) {
    if (message is SendPort) {
      _sendPort = message;
      if (!_ready.isCompleted) {
        _ready.complete();
      }
    } else if (message is TaskResult) {
      final completer = _tasks.remove(message.id);
      if (completer != null) {
        if (message.error != null) {
          completer.completeError(message.error!);
        } else {
          completer.complete(message.result);
        }
      }
    } else if (message is Exception) {
      _fail(message);
    } else if (message == null) {
      _fail(StateError('JS isolate exited unexpectedly'));
    } else if (message is List && message.length == 2) {
      final error = StateError('JS isolate crashed: ${message.first}');
      final stackTraceText = message.last?.toString();
      _fail(
        error,
        stackTraceText == null ? null : StackTrace.fromString(stackTraceText),
      );
    }
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_isClosed) {
      return;
    }
    Log.error('IsolateJsEngine', error, stackTrace);
    if (!_ready.isCompleted) {
      _ready.completeError(error, stackTrace);
    }
    for (final completer in _tasks.values) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
    _tasks.clear();
    close();
  }

  static void _run(_IsolateJsEngineInitParam params) async {
    var sendPort = params.sendPort;
    final port = ReceivePort();
    final engine = JsEngine();
    try {
      JsEngine.cacheJsInit(params.jsInit);
      await engine.init();
    } catch (e, s) {
      sendPort.send(Exception("Failed to initialize JS engine: $e\n$s"));
      port.close();
      return;
    }
    sendPort.send(port.sendPort);
    await for (final message in port) {
      if (message is Task) {
        JSInvokable? jsFunc;
        try {
          final value = engine.runCode(message.jsFunction);
          if (value is! JSInvokable) {
            throw Exception(
              "The provided code does not evaluate to a function.",
            );
          }
          jsFunc = value;
          final result = jsFunc.invoke(message.args);
          sendPort.send(TaskResult(message.id, result, null));
        } catch (e) {
          sendPort.send(TaskResult(message.id, null, e.toString()));
        } finally {
          jsFunc?.free();
        }
      }
    }
  }

  @override
  Future<dynamic> execute(String jsFunction, List<dynamic> args) async {
    if (_isClosed) {
      throw Exception("IsolateJsEngine is closed.");
    }
    await ready;
    final sendPort = _sendPort;
    if (_isClosed || sendPort == null) {
      throw Exception("IsolateJsEngine is closed.");
    }
    final completer = Completer<dynamic>();
    final taskId = _counter++;
    _tasks[taskId] = completer;
    final task = Task(taskId, jsFunction, args);
    sendPort.send(task);
    return completer.future;
  }

  @override
  void close() {
    if (!_isClosed) {
      _isClosed = true;
      final pendingTasks = _tasks.values.toList(growable: false);
      _tasks.clear();
      for (final completer in pendingTasks) {
        if (!completer.isCompleted) {
          completer.completeError(Exception("IsolateJsEngine is closed."));
        }
      }
      if (!_ready.isCompleted) {
        _ready.completeError(Exception("IsolateJsEngine is closed."));
      }
      _receivePort?.close();
      _receivePort = null;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
    }
  }
}

class Task {
  final int id;
  final String jsFunction;
  final List<dynamic> args;

  const Task(this.id, this.jsFunction, this.args);
}

class TaskResult {
  final int id;
  final Object? result;
  final String? error;

  const TaskResult(this.id, this.result, this.error);
}
