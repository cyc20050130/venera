import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart' show debugRunOutputFilePathExclusively;

void main() {
  test('cbz image extension detection is case insensitive', () {
    expect(isSupportedCbzImageExtension('jpg'), isTrue);
    expect(isSupportedCbzImageExtension('JPG'), isTrue);
    expect(isSupportedCbzImageExtension('.PNG'), isTrue);
    expect(isSupportedCbzImageExtension('webp'), isTrue);
    expect(isSupportedCbzImageExtension('txt'), isFalse);
  });

  test('comic archive entry validation rejects unsafe paths', () {
    for (final name in [
      '../outside.jpg',
      '/absolute.jpg',
      r'C:\absolute.jpg',
      'chapter/../../outside.jpg',
      '',
    ]) {
      expect(
        () => normalizeComicArchiveEntryName(name),
        throwsFormatException,
        reason: name,
      );
    }
    expect(normalizeComicArchiveEntryName(r'chapter\1.jpg'), 'chapter/1.jpg');
  });

  test('comic archive limits reject duplicates and expansion bombs', () {
    expect(
      () => validateComicArchiveEntries(const [
        (name: 'A.jpg', size: 10, isDirectory: false),
        (name: 'a.jpg', size: 10, isDirectory: false),
      ], archiveBytes: 100),
      throwsFormatException,
    );
    expect(
      () => validateComicArchiveEntries(
        const [(name: 'page.bmp', size: 1000, isDirectory: false)],
        archiveBytes: 1,
        maxExpandedBytes: 2000,
        maxCompressionRatio: 1,
        compressionRatioSlackBytes: 0,
      ),
      throwsFormatException,
    );
    expect(
      () => validateComicArchiveEntries(const [
        (name: 'page.jpg', size: 100, isDirectory: false),
      ], archiveBytes: 100),
      returnsNormally,
    );
  });

  test('ComicMetaData.fromJson tolerates malformed optional metadata', () {
    final metadata = ComicMetaData.fromJson({
      'title': 1,
      'author': null,
      'tags': ['tag', 2, null, ''],
      'chapters': [
        {'title': 3, 'start': '1', 'end': 2.7},
        'bad',
      ],
    });

    expect(metadata.title, '1');
    expect(metadata.author, '');
    expect(metadata.tags, ['tag', '2']);
    expect(metadata.chapters, hasLength(1));
    expect(metadata.chapters!.single.title, '3');
    expect(metadata.chapters!.single.start, 1);
    expect(metadata.chapters!.single.end, 2);
  });

  test('cbz import directory name avoids sanitized title collisions', () async {
    final tempDir = await Directory.systemTemp.createTemp('venera-cbz-');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    await Directory('${tempDir.path}/A B').create();
    await File('${tempDir.path}/A B/existing.txt').writeAsString('old');

    expect(buildCbzImportDirectoryName(tempDir.path, 'A:B'), 'A B(1)');
  });

  test('cbz temp paths are operation scoped', () {
    final output = File(
      '${Directory('library').path}${Platform.pathSeparator}comic.cbz',
    ).path;

    expect(
      buildCbzImportCacheDirectory('cache', 'op-1'),
      '${Directory('cache').path}${Platform.pathSeparator}cbz_import-op-1',
    );
    expect(
      buildCbzExportCacheDirectory('cache', 'op-1'),
      '${Directory('cache').path}${Platform.pathSeparator}cbz_export-op-1',
    );
    expect(
      buildCbzTemporaryOutputPath(output, 'op-1'),
      '${Directory('library').path}${Platform.pathSeparator}.comic.cbz.op-1.tmp',
    );
    expect(
      buildCbzBackupOutputPath(output, 'op-1'),
      '${Directory('library').path}${Platform.pathSeparator}.comic.cbz.op-1.bak',
    );
  });

  test('cbz output commit replaces existing file and removes backup', () async {
    final tempDir = await Directory.systemTemp.createTemp('venera-cbz-');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final output = File('${tempDir.path}${Platform.pathSeparator}comic.cbz');
    final temp = File('${tempDir.path}${Platform.pathSeparator}comic.tmp');
    final backup = File(
      '${tempDir.path}${Platform.pathSeparator}.comic.cbz.op.bak',
    );
    await output.writeAsString('old');
    await temp.writeAsString('new');

    await commitCbzTemporaryOutput(
      tempFile: temp,
      outputFile: output,
      backupFile: backup,
    );

    expect(await output.readAsString(), 'new');
    expect(await temp.exists(), isFalse);
    expect(await backup.exists(), isFalse);
  });

  test('cbz output commit restores existing file when replace fails', () async {
    final tempDir = await Directory.systemTemp.createTemp('venera-cbz-');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final output = File('${tempDir.path}${Platform.pathSeparator}comic.cbz');
    final missingTemp = File(
      '${tempDir.path}${Platform.pathSeparator}missing.tmp',
    );
    final backup = File(
      '${tempDir.path}${Platform.pathSeparator}.comic.cbz.op.bak',
    );
    await output.writeAsString('old');

    await expectLater(
      commitCbzTemporaryOutput(
        tempFile: missingTemp,
        outputFile: output,
        backupFile: backup,
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await output.readAsString(), 'old');
    expect(await backup.exists(), isFalse);
  });

  test('cbz output commit waits for same output path lock', () async {
    final tempDir = await Directory.systemTemp.createTemp('venera-cbz-');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final output = File('${tempDir.path}${Platform.pathSeparator}comic.cbz');
    final temp = File('${tempDir.path}${Platform.pathSeparator}comic.tmp');
    final backup = File(
      '${tempDir.path}${Platform.pathSeparator}.comic.cbz.op.bak',
    );
    await temp.writeAsString('new');

    final lockStarted = Completer<void>();
    final releaseLock = Completer<void>();
    final lock = debugRunOutputFilePathExclusively(output.path, () async {
      lockStarted.complete();
      await releaseLock.future;
    });

    await lockStarted.future;

    var committed = false;
    final commit =
        commitCbzTemporaryOutput(
          tempFile: temp,
          outputFile: output,
          backupFile: backup,
        ).then((_) {
          committed = true;
        });

    await Future<void>.delayed(Duration.zero);
    expect(committed, isFalse);
    expect(await output.exists(), isFalse);

    releaseLock.complete();
    await lock;
    await commit;

    expect(committed, isTrue);
    expect(await output.readAsString(), 'new');
  });
}
