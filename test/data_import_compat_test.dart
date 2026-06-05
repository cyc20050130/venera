import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/data.dart';

void main() {
  test('splitLegacyImageFavoriteId preserves hyphens in comic ids', () {
    final id = splitLegacyImageFavoriteId('source-comic-id-with-hyphen');

    expect(id?.sourceKey, 'source');
    expect(id?.comicId, 'comic-id-with-hyphen');
  });

  test('splitLegacyImageFavoriteId rejects invalid ids', () {
    expect(splitLegacyImageFavoriteId(null), isNull);
    expect(splitLegacyImageFavoriteId(1), isNull);
    expect(splitLegacyImageFavoriteId('source'), isNull);
    expect(splitLegacyImageFavoriteId('-comic'), isNull);
    expect(splitLegacyImageFavoriteId('source-'), isNull);
  });

  test('normalizePicaSourceKey migrates htmanga and rejects bad keys', () {
    expect(normalizePicaSourceKey('htmanga'), 'wnacg');
    expect(normalizePicaSourceKey('picacg'), 'picacg');
    expect(normalizePicaSourceKey(''), isNull);
    expect(normalizePicaSourceKey(null), isNull);
  });

  test('decodePicaFolderSyncId accepts only valid folder ids', () {
    expect(decodePicaFolderSyncId('{"folderId":"abc"}'), 'abc');
    expect(decodePicaFolderSyncId('{"folderId":1}'), isNull);
    expect(decodePicaFolderSyncId('[]'), isNull);
    expect(decodePicaFolderSyncId('{bad'), isNull);
  });

  test('normalizePicaComicType maps legacy source ids', () {
    expect(normalizePicaComicType(0), 'picacg'.hashCode);
    expect(normalizePicaComicType('4'), 'wnacg'.hashCode);
    expect(normalizePicaComicType(6), 'nhentai'.hashCode);
    expect(normalizePicaComicType(99), 99);
    expect(normalizePicaComicType(null), isNull);
  });

  test('splitPicaTags and normalizePicaInt tolerate malformed values', () {
    expect(splitPicaTags('a,,b'), ['a', 'b']);
    expect(splitPicaTags(null), isEmpty);
    expect(normalizePicaInt('12'), 12);
    expect(normalizePicaInt('bad', fallback: 7), 7);
  });

  test('normalizePicaFavoriteFolderTables rejects unsafe imported tables', () {
    expect(
      normalizePicaFavoriteFolderTables([
        'Safe',
        'bad"name',
        'folder_order',
        'folder_sync',
        '',
        null,
      ]),
      {'Safe': 'Safe'},
    );
  });

  test('decodeImportedAppData accepts only json objects', () {
    expect(decodeImportedAppData('{"settings":{"dataVersion":"2"}}'), {
      'settings': {'dataVersion': '2'},
    });
    expect(decodeImportedAppData('[]'), isNull);
    expect(decodeImportedAppData('{bad'), isNull);
  });

  test('buildAppDataExportEntries skips missing optional files', () {
    final entries = buildAppDataExportEntries(
      'Z:/definitely/missing/venera',
      sync: true,
    );

    expect(entries, isEmpty);
  });

  test('app data temporary paths are operation scoped', () {
    final exportFile = buildAppDataExportFile(
      'cache-root',
      operationId: 'op-1',
    );
    final importDir = buildAppDataImportDirectory(
      'cache-root',
      'appdata-import',
      operationId: 'op-2',
    );

    expect(exportFile.path, contains('appdata-export-op-1.venera'));
    expect(importDir.path, contains('appdata-import-op-2'));
    expect(exportFile.path, isNot(contains('temp_data')));
    expect(importDir.path, isNot(contains('temp_data')));
    expect(exportFile.path, isNot(contains('import_data_temp')));
    expect(importDir.path, isNot(contains('import_data_temp')));
  });

  test('data import sessions do not overlap', () async {
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final secondEntered = Completer<void>();
    final events = <String>[];
    var activeCount = 0;

    final first = debugRunDataImportExclusively(() async {
      activeCount++;
      events.add('first-start');
      firstEntered.complete();
      await releaseFirst.future;
      events.add('first-end');
      activeCount--;
    });

    await firstEntered.future;

    final second = debugRunDataImportExclusively(() async {
      activeCount++;
      events.add('second-start');
      expect(activeCount, 1);
      secondEntered.complete();
      events.add('second-end');
      activeCount--;
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-start']);

    releaseFirst.complete();
    await secondEntered.future.timeout(const Duration(seconds: 2));
    await Future.wait([first, second]);

    expect(events, ['first-start', 'first-end', 'second-start', 'second-end']);
    expect(activeCount, 0);
  });

  test('data import lock releases after failures', () async {
    await expectLater(
      debugRunDataImportExclusively<void>(() async {
        throw StateError('import failed');
      }),
      throwsA(isA<StateError>()),
    );

    var completed = false;
    await debugRunDataImportExclusively(() async {
      completed = true;
    }).timeout(const Duration(seconds: 2));

    expect(completed, isTrue);
  });
}
