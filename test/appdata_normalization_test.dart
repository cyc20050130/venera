import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  test('normalizeDisableSyncFields keeps only string values', () {
    expect(normalizeDisableSyncFields('webdav, proxy'), 'webdav, proxy');
    expect(normalizeDisableSyncFields(null), '');
    expect(normalizeDisableSyncFields(['webdav']), '');
    expect(normalizeDisableSyncFields(1), '');
  });

  test('normalizeDeviceId keeps only string values', () {
    expect(normalizeDeviceId('device-id'), 'device-id');
    expect(normalizeDeviceId(null), '');
    expect(normalizeDeviceId(1), '');
  });

  test('normalizeDataVersion accepts only non-negative versions', () {
    expect(normalizeDataVersion(3), 3);
    expect(normalizeDataVersion('4'), 4);
    expect(normalizeDataVersion(-1), 0);
    expect(normalizeDataVersion('-1'), 0);
    expect(normalizeDataVersion('bad'), 0);
    expect(normalizeDataVersion(null), 0);
  });

  test('normalizeSearchHistory keeps only non-empty string values', () {
    expect(normalizeSearchHistory(['a', '', 1, 'b']), ['a', 'b']);
    expect(normalizeSearchHistory('keyword'), isEmpty);
    expect(normalizeSearchHistory(null), isEmpty);
    expect(
      normalizeSearchHistory(List.generate(60, (i) => 'k$i')),
      hasLength(50),
    );
  });

  test('normalizeImplicitData accepts only map roots', () {
    expect(normalizeImplicitData({'a': 1, 2: 'b'}), {'a': 1, '2': 'b'});
    expect(normalizeImplicitData(['bad']), isEmpty);
    expect(normalizeImplicitData(null), isEmpty);
  });

  test('normalizeStringListSetting keeps only non-empty string values', () {
    expect(normalizeStringListSetting(['a', '', 1, 'b']), ['a', 'b']);
    expect(normalizeStringListSetting('a'), isEmpty);
    expect(normalizeStringListSetting(null), isEmpty);
  });

  test('Settings.stringList tolerates malformed synced values', () {
    final previous = appdata.settings['blockedWords'];
    addTearDown(() => appdata.settings['blockedWords'] = previous);

    appdata.settings['blockedWords'] = 'bad';
    expect(appdata.settings.stringList('blockedWords'), isEmpty);

    appdata.settings['blockedWords'] = ['keep', 1, '', 'also'];
    expect(appdata.settings.stringList('blockedWords'), ['keep', 'also']);
  });

  test(
    'writeImplicitData completes when the target path cannot be written',
    () async {
      String? previousPath;
      try {
        previousPath = App.dataPath;
      } catch (_) {
        previousPath = null;
      }
      final tempDir = await Directory.systemTemp.createTemp('venera-appdata-');
      final blockingFile = File('${tempDir.path}/not-a-directory');
      await blockingFile.writeAsString('block');
      addTearDown(() async {
        App.dataPath = previousPath ?? Directory.systemTemp.path;
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      App.dataPath = blockingFile.path;
      appdata.implicitData['write-test'] = DateTime.now().toIso8601String();

      await expectLater(appdata.writeImplicitData(), completes);
    },
  );

  test(
    'saveData removes stale syncdata when sync filtering is disabled',
    () async {
      String? previousPath;
      try {
        previousPath = App.dataPath;
      } catch (_) {
        previousPath = null;
      }
      final previousDisableSync = appdata.settings['disableSyncFields'];
      final tempDir = await Directory.systemTemp.createTemp('venera-appdata-');
      addTearDown(() async {
        App.dataPath = previousPath ?? Directory.systemTemp.path;
        appdata.settings['disableSyncFields'] = previousDisableSync;
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      App.dataPath = tempDir.path;
      final staleSyncData = File('${tempDir.path}/syncdata.json');
      await staleSyncData.writeAsString('stale');
      appdata.settings['disableSyncFields'] = '';

      await appdata.saveData(false);

      expect(await File('${tempDir.path}/appdata.json').exists(), isTrue);
      expect(await staleSyncData.exists(), isFalse);
    },
  );

  test('string and bool settings tolerate malformed synced values', () {
    final previousMode = appdata.settings['readerMode'];
    final previousComments = appdata.settings['showChapterComments'];
    addTearDown(() {
      appdata.settings['readerMode'] = previousMode;
      appdata.settings['showChapterComments'] = previousComments;
    });

    expect(normalizeStringSetting('gallery', 'fallback'), 'gallery');
    expect(normalizeStringSetting(1, 'fallback'), 'fallback');
    expect(normalizeBoolSetting(true, false), isTrue);
    expect(normalizeBoolSetting('false', true), isFalse);
    expect(normalizeBoolSetting(1, false), isTrue);
    expect(normalizeBoolSetting('bad', true), isTrue);

    appdata.settings['readerMode'] = 1;
    expect(
      appdata.settings.stringValue(
        'readerMode',
        fallback: 'galleryLeftToRight',
      ),
      'galleryLeftToRight',
    );

    appdata.settings['showChapterComments'] = 'false';
    expect(
      appdata.settings.boolValue('showChapterComments', fallback: true),
      isFalse,
    );
  });

  test('normalizeNumSetting accepts numeric strings', () {
    expect(normalizeNumSetting(3, 1), 3);
    expect(normalizeNumSetting(3.5, 1), 3.5);
    expect(normalizeNumSetting('4', 1), 4);
    expect(normalizeNumSetting('bad', 1), 1);
    expect(normalizeNumSetting(null, 1), 1);
  });

  test('Settings numeric helpers clamp malformed values', () {
    final previousThreads = appdata.settings['downloadThreads'];
    final previousScale = appdata.settings['comicTileScale'];
    addTearDown(() {
      appdata.settings['downloadThreads'] = previousThreads;
      appdata.settings['comicTileScale'] = previousScale;
    });

    appdata.settings['downloadThreads'] = '0';
    expect(
      appdata.settings.intValue('downloadThreads', fallback: 5, min: 1),
      1,
    );

    appdata.settings['comicTileScale'] = '2';
    expect(
      appdata.settings.doubleValue(
        'comicTileScale',
        fallback: 1,
        min: 0.75,
        max: 1.25,
      ),
      1.25,
    );
  });

  test('reader specific settings recover malformed map values', () {
    final previousComic = appdata.settings['comicSpecificSettings'];
    final previousDevice = appdata.settings['deviceSpecificSettings'];
    final previousDeviceId = appdata.settings['deviceId'];
    addTearDown(() {
      appdata.settings['comicSpecificSettings'] = previousComic;
      appdata.settings['deviceSpecificSettings'] = previousDevice;
      appdata.settings['deviceId'] = previousDeviceId;
    });

    appdata.settings['comicSpecificSettings'] = 'bad';
    expect(
      appdata.settings.isComicSpecificSettingsEnabled('comic', 'source'),
      isFalse,
    );
    appdata.settings.setReaderSetting('comic', 'source', 'enabled', true);
    expect(
      appdata.settings.isComicSpecificSettingsEnabled('comic', 'source'),
      isTrue,
    );

    appdata.settings['deviceId'] = 'device';
    appdata.settings['deviceSpecificSettings'] = {'device': 'bad'};
    expect(appdata.settings.isDeviceSpecificSettingsEnabled(), isFalse);
    appdata.settings.setDeviceReaderSetting('enabled', true);
    expect(appdata.settings.isDeviceSpecificSettingsEnabled(), isTrue);
  });
}
