import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/io.dart';

void main() {
  tearDown(() {
    IO.debugResetSelectingFiles();
  });

  test('localFilePathFromUri preserves plain paths', () {
    expect(
      localFilePathFromUri(r'C:\Comics\1.jpg', windows: true),
      r'C:\Comics\1.jpg',
    );
    expect(
      localFilePathFromUri('/tmp/comics/1.jpg', windows: false),
      '/tmp/comics/1.jpg',
    );
  });

  test('localFilePathFromUri handles legacy file uri paths', () {
    expect(
      localFilePathFromUri(r'file://C:\Comics\A%20B.jpg', windows: true),
      r'C:\Comics\A B.jpg',
    );
    expect(
      localFilePathFromUri('file:///tmp/comics/A%20B.jpg', windows: false),
      '/tmp/comics/A B.jpg',
    );
  });

  test('localFilePathFromUri handles standard windows file uris', () {
    expect(
      localFilePathFromUri('file:///C:/Comics/A%20B.jpg', windows: true),
      r'C:\Comics\A B.jpg',
    );
  });

  test(
    'localFilePathFromUri preserves malformed percent encoding fallback',
    () {
      expect(
        localFilePathFromUri('file:///tmp/comics/%ZZ.jpg', windows: false),
        '/tmp/comics/%ZZ.jpg',
      );
      expect(
        localFilePathFromUri(r'file://C:\Comics\%ZZ.jpg', windows: true),
        r'C:\Comics\%ZZ.jpg',
      );
    },
  );

  test('isAllowedSelectedFileExtension is case insensitive', () {
    expect(isAllowedSelectedFileExtension('comic.CBZ', ['cbz']), isTrue);
    expect(isAllowedSelectedFileExtension('comic.zip', ['CBZ', 'ZIP']), isTrue);
    expect(isAllowedSelectedFileExtension('comic.txt', ['cbz']), isFalse);
  });

  test(
    'file selection guard remains active for overlapping operations',
    () async {
      IO.debugBeginSelectingFiles();
      IO.debugBeginSelectingFiles();

      expect(IO.isSelectingFiles, isTrue);
      expect(IO.debugSelectingFilesCount, 2);

      await IO.debugEndSelectingFilesAfter();

      expect(IO.isSelectingFiles, isTrue);
      expect(IO.debugSelectingFilesCount, 1);

      await IO.debugEndSelectingFilesAfter();

      expect(IO.isSelectingFiles, isFalse);
      expect(IO.debugSelectingFilesCount, 0);
    },
  );

  test('saveFile data cache path is operation scoped', () {
    expect(
      buildSaveFileCachePath('cache', 'cover.jpg', 'op-1'),
      '${Directory('cache').path}${Platform.pathSeparator}save_file-op-1'
      '${Platform.pathSeparator}cover.jpg',
    );
    expect(
      buildSaveFileCachePath('cache', 'cover.jpg', 'op-1'),
      isNot(buildSaveFileCachePath('cache', 'cover.jpg', 'op-2')),
    );
  });

  test('shareFile windows cache path is operation scoped', () {
    expect(
      buildShareFileCachePath('cache', 'image.jpg', 'op-1'),
      '${Directory('cache').path}${Platform.pathSeparator}share_file-op-1'
      '${Platform.pathSeparator}image.jpg',
    );
    expect(
      buildShareFileCachePath('cache', 'image.jpg', 'op-1'),
      isNot(buildShareFileCachePath('cache', 'image.jpg', 'op-2')),
    );
  });

  test('direct access directory cache path is operation scoped', () {
    expect(
      buildSelectedDirectoryCachePath('cache', 'op-1'),
      '${Directory('cache').path}${Platform.pathSeparator}'
      'selected_directory-op-1',
    );
    expect(
      buildSelectedDirectoryCachePath('cache', 'op-1'),
      isNot(buildSelectedDirectoryCachePath('cache', 'op-2')),
    );
  });

  test('cache path containment requires a real directory boundary', () {
    expect(
      isPathInsideDirectory('/tmp/venera/cache/file.jpg', '/tmp/venera/cache'),
      isTrue,
    );
    expect(
      isPathInsideDirectory('/tmp/venera/cache', '/tmp/venera/cache'),
      isTrue,
    );
    expect(
      isPathInsideDirectory(
        '/tmp/venera/cache-old/file.jpg',
        '/tmp/venera/cache',
      ),
      isFalse,
    );
    expect(
      isPathInsideDirectory(
        '/tmp/venera/cache_backup/file.jpg',
        '/tmp/venera/cache',
      ),
      isFalse,
    );
  });

  test('cache path containment normalizes windows paths and file uris', () {
    expect(
      isPathInsideDirectory(
        r'C:\Venera\Cache\File.jpg',
        r'c:\venera\cache',
        windows: true,
      ),
      isTrue,
    );
    expect(
      isPathInsideDirectory(
        'file:///C:/Venera/Cache/File.jpg',
        r'C:\Venera\Cache',
        windows: true,
      ),
      isTrue,
    );
    expect(
      isPathInsideDirectory(
        r'C:\Venera\Cache-old\File.jpg',
        r'C:\Venera\Cache',
        windows: true,
      ),
      isFalse,
    );
  });

  test('copyDirectory waits for nested directory copies', () async {
    final tempDir = await Directory.systemTemp.createTemp('venera-copy-dir-');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final source = await Directory(
      FilePath.join(tempDir.path, 'source'),
    ).create();
    final nested = await Directory(
      FilePath.join(source.path, 'nested'),
    ).create();
    await File(FilePath.join(nested.path, 'image.jpg')).writeAsBytes([1, 2, 3]);
    final destination = await Directory(
      FilePath.join(tempDir.path, 'destination'),
    ).create();

    await copyDirectory(source, destination);

    expect(
      await File(
        FilePath.join(destination.path, 'nested', 'image.jpg'),
      ).readAsBytes(),
      [1, 2, 3],
    );
  });

  test('output file path lock serializes same output path', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'venera-output-lock-',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final outputPath = FilePath.join(tempDir.path, 'comic.cbz');
    final firstStarted = Completer<void>();
    final allowFirstToFinish = Completer<void>();
    final events = <String>[];

    final first = debugRunOutputFilePathExclusively(outputPath, () async {
      events.add('first-start');
      firstStarted.complete();
      await allowFirstToFinish.future;
      events.add('first-end');
      return 1;
    });

    await firstStarted.future;

    var secondStarted = false;
    final second = debugRunOutputFilePathExclusively(outputPath, () async {
      secondStarted = true;
      events.add('second-start');
      return 2;
    });

    await Future<void>.delayed(Duration.zero);
    expect(secondStarted, isFalse);

    allowFirstToFinish.complete();

    expect(await first, 1);
    expect(await second, 2);
    expect(events, ['first-start', 'first-end', 'second-start']);
  });

  test(
    'output file path lock allows different output paths concurrently',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'venera-output-lock-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final allowFinish = Completer<void>();

      final first = debugRunOutputFilePathExclusively(
        FilePath.join(tempDir.path, 'a.cbz'),
        () async {
          firstStarted.complete();
          await allowFinish.future;
          return 1;
        },
      );
      final second = debugRunOutputFilePathExclusively(
        FilePath.join(tempDir.path, 'b.cbz'),
        () async {
          secondStarted.complete();
          await allowFinish.future;
          return 2;
        },
      );

      await firstStarted.future;
      await secondStarted.future;
      allowFinish.complete();

      expect(await first, 1);
      expect(await second, 2);
    },
  );

  test('output lock normalizes windows path casing', () {
    expect(
      normalizeOutputFilePathForLock(r'C:\Library\Comic.CBZ', windows: true),
      normalizeOutputFilePathForLock(r'c:\library\comic.cbz', windows: true),
    );
  });
}
