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

  test('notification warning follows Android permission and channel state', () {
    expect(
      backgroundTaskNotificationNeedsAttention(
        true,
        BackgroundTaskNotificationPermission.enabled,
      ),
      isFalse,
    );
    expect(
      backgroundTaskNotificationNeedsAttention(
        true,
        BackgroundTaskNotificationPermission.channelDisabled,
      ),
      isTrue,
    );
    expect(
      backgroundTaskNotificationNeedsAttention(
        false,
        BackgroundTaskNotificationPermission.disabled,
      ),
      isFalse,
    );
  });

  test('background progress translation preserves counters and errors', () {
    expect(
      translateBackgroundTaskProgressText(
        'Writing compressed file 4/10',
        translate: (key) => key == 'Writing compressed file' ? '写入压缩文件' : key,
      ),
      '写入压缩文件 4/10',
    );
    expect(
      translateBackgroundTaskProgressText('Error: disk full'),
      endsWith(': disk full'),
    );
  });
}
