import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/perf_trace.dart';

void main() {
  tearDown(PerfTrace.debugReset);

  test('trace events have stable structured fields', () {
    final events = <PerfTraceEvent>[];
    PerfTrace.debugConfigure(isEnabled: true, sink: events.add);

    PerfTrace.instant(
      'archive inspect',
      component: 'LocalArchive',
      elapsed: const Duration(milliseconds: 42),
      attributes: const {'comicCount': 3, 'path': 'a b'},
    );

    expect(events, hasLength(1));
    expect(
      events.single.toLogLine(),
      '[perf] operation=archive_inspect elapsedMs=42 outcome=success '
      'comicCount=3 path=a_b',
    );
  });

  test('measure reports success and preserves attributes', () async {
    final events = <PerfTraceEvent>[];
    PerfTrace.debugConfigure(isEnabled: true, sink: events.add);

    final value = await PerfTrace.measure(
      'query',
      component: 'Database',
      attributes: const {'table': 'history'},
      action: () async => 7,
    );

    expect(value, 7);
    expect(events.single.outcome, PerfTraceOutcome.success);
    expect(events.single.attributes, {'table': 'history'});
  });

  test('measure classifies cancellation and rethrows', () async {
    final events = <PerfTraceEvent>[];
    PerfTrace.debugConfigure(isEnabled: true, sink: events.add);

    await expectLater(
      PerfTrace.measure<void>(
        'restore',
        component: 'LocalArchive',
        action: () => throw const _Cancelled(),
        isCancellation: (error) => error is _Cancelled,
      ),
      throwsA(isA<_Cancelled>()),
    );

    expect(events.single.outcome, PerfTraceOutcome.cancelled);
    expect(events.single.attributes['errorType'], _Cancelled);
  });

  test('finishing a span more than once only emits once', () {
    final events = <PerfTraceEvent>[];
    PerfTrace.debugConfigure(isEnabled: true, sink: events.add);

    final span = PerfTrace.start('startup', component: 'Bootstrap');
    span.finish();
    span.finish(outcome: PerfTraceOutcome.failure);

    expect(events, hasLength(1));
  });

  test('disabled tracing does not call sink', () {
    final events = <PerfTraceEvent>[];
    PerfTrace.debugConfigure(isEnabled: false, sink: events.add);

    PerfTrace.instant('quiet', component: 'Test');

    expect(events, isEmpty);
  });
}

class _Cancelled implements Exception {
  const _Cancelled();
}
