import 'dart:async';

import 'package:flutter/foundation.dart';

/// A mixin class that provides a way to ensure the class is initialized.
abstract mixin class Init {
  bool _isInit = false;

  Future<void>? _initFuture;

  int _generation = 0;

  final _initCompleter = <Completer<void>>[];

  /// Ensure the class is initialized.
  Future<void> ensureInit() async {
    if (_isInit) {
      return;
    }
    var completer = Completer<void>();
    _initCompleter.add(completer);
    return completer.future;
  }

  Future<void> _markInit() async {
    _isInit = true;
    for (var completer in _initCompleter) {
      completer.complete();
    }
    _initCompleter.clear();
  }

  @protected
  void markUninitialized() {
    _generation++;
    _isInit = false;
    _initFuture = null;
    for (var completer in _initCompleter) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _initCompleter.clear();
  }

  @protected
  Future<void> doInit();

  /// Initialize the class.
  Future<void> init() async {
    if (_isInit) {
      return;
    }
    final pending = _initFuture;
    if (pending != null) {
      return pending;
    }
    final generation = _generation;
    late final Future<void> operation;
    operation = () async {
      try {
        await doInit();
        if (generation == _generation) {
          await _markInit();
        }
      } catch (error, stackTrace) {
        if (generation == _generation) {
          final waiters = _initCompleter.toList(growable: false);
          _initCompleter.clear();
          for (final waiter in waiters) {
            if (!waiter.isCompleted) {
              waiter.completeError(error, stackTrace);
            }
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        if (identical(_initFuture, operation)) {
          _initFuture = null;
        }
      }
    }();
    _initFuture = operation;
    return operation;
  }
}
