import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/background_task_notification.dart';

void main() {
  test('background task notification exposes live progress and ETA', () {
    const data = BackgroundTaskNotificationData(
      taskKey: 'task',
      operation: 'Compressing',
      title: 'Comic',
      message: 'Writing compressed file 4/10',
      progress: 0.42,
      speed: 1024,
      isPaused: false,
      isError: false,
      estimatedRemaining: Duration(minutes: 1, seconds: 5),
    );

    expect(buildBackgroundTaskNotificationTitle(data), 'Compressing: Comic');
    expect(buildBackgroundTaskNotificationBody(data), contains('42%'));
    expect(buildBackgroundTaskNotificationBody(data), contains('1.00 KB/s'));
    expect(buildBackgroundTaskNotificationBody(data), contains('1:05'));
  });

  test('unknown task progress remains indeterminate', () {
    const data = BackgroundTaskNotificationData(
      taskKey: 'task',
      operation: 'Downloading',
      title: '',
      message: 'Fetching comic info...',
      progress: 0,
      speed: 0,
      isPaused: false,
      isError: false,
      hasDeterminateProgress: false,
    );

    expect(buildBackgroundTaskNotificationTitle(data), 'Downloading');
    expect(buildBackgroundTaskNotificationBody(data), 'Fetching comic info...');
  });
}
