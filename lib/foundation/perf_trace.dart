import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/log.dart';

enum PerfTraceOutcome { success, failure, cancelled }

typedef PerfTraceSink = void Function(PerfTraceEvent event);

@immutable
class PerfTraceEvent {
  const PerfTraceEvent({
    required this.component,
    required this.operation,
    required this.elapsed,
    required this.outcome,
    this.attributes = const <String, Object?>{},
  });

  final String component;
  final String operation;
  final Duration elapsed;
  final PerfTraceOutcome outcome;
  final Map<String, Object?> attributes;

  String toLogLine() {
    final fields = <String>[
      '[perf]',
      'operation=${_sanitize(operation)}',
      'elapsedMs=${elapsed.inMilliseconds}',
      'outcome=${outcome.name}',
    ];
    final keys = attributes.keys.toList(growable: false)..sort();
    for (final key in keys) {
      final value = attributes[key];
      if (value == null) continue;
      fields.add('${_sanitize(key)}=${_sanitize(value)}');
    }
    return fields.join(' ');
  }

  static String _sanitize(Object value) {
    final normalized = value
        .toString()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll('=', ':');
    return normalized.length <= 160
        ? normalized
        : '${normalized.substring(0, 157)}...';
  }
}

/// Small, dependency-free performance tracing used by startup and long tasks.
///
/// Debug builds emit traces by default. Profile/release builds can opt in with
/// `--dart-define=VENERA_PERF_TRACE=true`, keeping normal release logs quiet.
final class PerfTrace {
  PerfTrace._();

  static const bool _enabledByEnvironment = bool.fromEnvironment(
    'VENERA_PERF_TRACE',
  );

  static bool enabled = kDebugMode || _enabledByEnvironment;
  static PerfTraceSink _sink = _defaultSink;

  static PerfTraceSpan start(
    String operation, {
    required String component,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    return PerfTraceSpan._(
      component: component,
      operation: operation,
      attributes: attributes,
      stopwatch: Stopwatch()..start(),
    );
  }

  static void instant(
    String operation, {
    required String component,
    Duration elapsed = Duration.zero,
    PerfTraceOutcome outcome = PerfTraceOutcome.success,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    _emit(
      PerfTraceEvent(
        component: component,
        operation: operation,
        elapsed: elapsed,
        outcome: outcome,
        attributes: attributes,
      ),
    );
  }

  static Future<T> measure<T>(
    String operation, {
    required String component,
    Map<String, Object?> attributes = const <String, Object?>{},
    required FutureOr<T> Function() action,
    bool Function(Object error)? isCancellation,
  }) async {
    final span = start(operation, component: component, attributes: attributes);
    try {
      final result = await action();
      span.finish();
      return result;
    } catch (error) {
      span.finish(
        outcome: isCancellation?.call(error) == true
            ? PerfTraceOutcome.cancelled
            : PerfTraceOutcome.failure,
        attributes: <String, Object?>{'errorType': error.runtimeType},
      );
      rethrow;
    }
  }

  static void _emit(PerfTraceEvent event) {
    if (!enabled) return;
    _sink(event);
  }

  static void _defaultSink(PerfTraceEvent event) {
    Log.info(event.component, event.toLogLine());
  }

  @visibleForTesting
  static void debugConfigure({bool? isEnabled, PerfTraceSink? sink}) {
    if (isEnabled != null) enabled = isEnabled;
    if (sink != null) _sink = sink;
  }

  @visibleForTesting
  static void debugReset() {
    enabled = kDebugMode || _enabledByEnvironment;
    _sink = _defaultSink;
  }
}

final class PerfTraceSpan {
  PerfTraceSpan._({
    required this.component,
    required this.operation,
    required this.attributes,
    required Stopwatch stopwatch,
  }) : _stopwatch = stopwatch;

  final String component;
  final String operation;
  final Map<String, Object?> attributes;
  final Stopwatch _stopwatch;
  bool _finished = false;

  void finish({
    PerfTraceOutcome outcome = PerfTraceOutcome.success,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    if (_finished) return;
    _finished = true;
    _stopwatch.stop();
    PerfTrace._emit(
      PerfTraceEvent(
        component: component,
        operation: operation,
        elapsed: _stopwatch.elapsed,
        outcome: outcome,
        attributes: <String, Object?>{...this.attributes, ...attributes},
      ),
    );
  }
}
