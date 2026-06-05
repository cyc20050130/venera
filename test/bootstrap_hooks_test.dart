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

  test('startWindowsHeartbeat swallows heartbeat failures', () async {
    var attempts = 0;
    final timer = startWindowsHeartbeat(
      enabled: true,
      interval: const Duration(milliseconds: 10),
      sendHeartbeat: () async {
        attempts++;
        throw StateError('heartbeat boom');
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 35));
    timer?.cancel();

    expect(attempts, greaterThanOrEqualTo(2));
  });

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

  test('normalizeCacheSizeMb tolerates malformed synced values', () {
    expect(normalizeCacheSizeMb(512), 512);
    expect(normalizeCacheSizeMb('1024'), 1024);
    expect(normalizeCacheSizeMb(1.9), 1);
    expect(normalizeCacheSizeMb('bad'), 2048);
    expect(normalizeCacheSizeMb(0), 2048);
    expect(normalizeCacheSizeMb(-1), 2048);
    expect(normalizeCacheSizeMb(['2048']), 2048);
    expect(normalizeCacheSizeMb(null), 2048);
  });

  test('shouldCheckUpdateOnStart tolerates malformed synced values', () {
    expect(shouldCheckUpdateOnStart(true), isTrue);
    expect(shouldCheckUpdateOnStart(false), isFalse);
    expect(shouldCheckUpdateOnStart('true'), isTrue);
    expect(shouldCheckUpdateOnStart('false'), isFalse);
    expect(shouldCheckUpdateOnStart(1), isTrue);
    expect(shouldCheckUpdateOnStart(0), isFalse);
    expect(shouldCheckUpdateOnStart('bad'), isFalse);
    expect(shouldCheckUpdateOnStart(['true']), isFalse);
    expect(shouldCheckUpdateOnStart(null), isFalse);
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

  test(
    'startup background task waits for lifecycle resume quiet window',
    () async {
      final controller = BootstrapController(
        startupInteractionProtectionWindow: Duration.zero,
      );
      var runs = 0;

      controller.phaseBReady = true;
      controller.debugCompletePhaseBForTest();
      controller.markHomeInteractive();
      controller.markLifecycleResumed(
        quietWindow: const Duration(milliseconds: 50),
      );
      controller.scheduleStartupBackgroundTask(
        'resume-quiet',
        Duration.zero,
        () {
          runs++;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runs, 0);

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(runs, 1);
    },
  );
}
