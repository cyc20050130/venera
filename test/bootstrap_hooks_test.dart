import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/bootstrap.dart';

void main() {
  test('guardBootstrapTask swallows startup failures', () async {
    await expectLater(
      guardBootstrapTask(Future<void>.error(StateError('boom'))),
      completes,
    );
  });

  test(
    'startWindowsHeartbeat emits periodic heartbeats when enabled',
    () async {
      var count = 0;
      final timer = startWindowsHeartbeat(
        enabled: true,
        interval: const Duration(milliseconds: 10),
        sendHeartbeat: () async {
          count++;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 35));
      timer?.cancel();

      expect(count, greaterThanOrEqualTo(2));
    },
  );

  test('installFlutterErrorLogger forwards Flutter framework exceptions', () {
    String? title;
    Object? message;

    installFlutterErrorLogger(
      logError: (capturedTitle, capturedMessage) {
        title = capturedTitle;
        message = capturedMessage;
      },
    );

    FlutterError.onError?.call(
      FlutterErrorDetails(
        exception: StateError('framework boom'),
        stack: StackTrace.empty,
      ),
    );

    expect(title, 'Unhandled Exception');
    expect(message.toString(), contains('framework boom'));
  });

  test(
    'installBootstrapStartupHooks installs logger and heartbeat immediately',
    () async {
      String? title;
      Object? message;
      var heartbeats = 0;

      final timer = installBootstrapStartupHooks(
        enableWindowsHeartbeat: true,
        heartbeatInterval: const Duration(milliseconds: 10),
        sendHeartbeat: () async {
          heartbeats++;
        },
        logError: (capturedTitle, capturedMessage) {
          title = capturedTitle;
          message = capturedMessage;
        },
      );

      FlutterError.onError?.call(
        FlutterErrorDetails(
          exception: StateError('startup boom'),
          stack: StackTrace.empty,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 35));
      timer?.cancel();

      expect(title, 'Unhandled Exception');
      expect(message.toString(), contains('startup boom'));
      expect(heartbeats, greaterThanOrEqualTo(2));
    },
  );

  test('startup background task waits for home interactive', () async {
    final controller = BootstrapController(
      startupInteractionProtectionWindow: Duration.zero,
    );
    var runs = 0;

    controller.scheduleStartupBackgroundTask('probe', Duration.zero, () {
      runs++;
    });

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runs, 0);

    controller.phaseBReady = true;
    controller.debugCompletePhaseBForTest();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runs, 0);

    controller.markHomeInteractive();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runs, 1);
  });

  test('startup background task names are scheduled once', () async {
    final controller = BootstrapController(
      startupInteractionProtectionWindow: Duration.zero,
    );
    var runs = 0;

    controller.phaseBReady = true;
    controller.debugCompletePhaseBForTest();
    controller.markHomeInteractive();
    controller.scheduleStartupBackgroundTask('same', Duration.zero, () {
      runs++;
    });
    controller.scheduleStartupBackgroundTask('same', Duration.zero, () {
      runs++;
    });

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runs, 1);
  });
}
