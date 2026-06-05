import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';

void main() {
  test('resolveConfiguredLocale accepts supported language settings', () {
    expect(resolveConfiguredLocale('zh-CN'), const Locale('zh', 'CN'));
    expect(resolveConfiguredLocale('zh-TW'), const Locale('zh', 'TW'));
    expect(resolveConfiguredLocale('en-US'), const Locale('en', 'US'));
    expect(resolveConfiguredLocale('en'), const Locale('en'));
  });

  test('resolveConfiguredLocale ignores malformed synced values', () {
    expect(resolveConfiguredLocale('system'), isNull);
    expect(resolveConfiguredLocale(''), isNull);
    expect(resolveConfiguredLocale('zh'), isNull);
    expect(resolveConfiguredLocale(1), isNull);
    expect(resolveConfiguredLocale(null), isNull);
  });

  test('Android external storage path falls back to data path', () {
    expect(resolveAndroidExternalStoragePath(null, '/app/data'), '/app/data');
    expect(resolveAndroidExternalStoragePath('', '/app/data'), '/app/data');
    expect(
      resolveAndroidExternalStoragePath('/external', '/app/data'),
      '/external',
    );
  });

  test(
    'log directory path falls back when Android external storage is absent',
    () {
      expect(
        resolveLogDirectoryPath(
          isAndroid: true,
          dataPath: '/app/data',
          externalStoragePath: null,
        ),
        '/app/data',
      );
      expect(
        resolveLogDirectoryPath(
          isAndroid: true,
          dataPath: '/app/data',
          externalStoragePath: '',
        ),
        '/app/data',
      );
      expect(
        resolveLogDirectoryPath(
          isAndroid: true,
          dataPath: '/app/data',
          externalStoragePath: '/external',
        ),
        '/external',
      );
      expect(
        resolveLogDirectoryPath(
          isAndroid: false,
          dataPath: '/app/data',
          externalStoragePath: '/external',
        ),
        '/app/data',
      );
    },
  );

  test('force rebuild handler unregisters by identity only', () {
    var firstCalls = 0;
    var secondCalls = 0;
    void first() => firstCalls++;
    void second() => secondCalls++;

    App.registerForceRebuild(first);
    expect(App.hasForceRebuildHandler, isTrue);
    App.unregisterForceRebuild(second);
    App.forceRebuild();
    expect(firstCalls, 1);
    expect(secondCalls, 0);

    App.registerForceRebuild(second);
    App.unregisterForceRebuild(first);
    App.forceRebuild();
    expect(firstCalls, 1);
    expect(secondCalls, 1);

    App.unregisterForceRebuild(second);
    expect(App.hasForceRebuildHandler, isFalse);
  });
}
