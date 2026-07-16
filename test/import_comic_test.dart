import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';

void main() {
  late Directory tempDir;
  late LocalManager manager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-import-comic-');
    App.dataPath = tempDir.path;
    LocalManager.debugResetInstance();
    manager = LocalManager();
    await manager.init();
  });

  tearDown(() async {
    manager.dispose();
    LocalManager.debugResetInstance();
    if (await tempDir.exists()) {
      for (var i = 0; i < 5; i++) {
        try {
          await tempDir.delete(recursive: true);
          break;
        } on FileSystemException {
          if (i == 4) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  });

  test('local directory import detects uppercase image extensions', () async {
    final comicDir = await Directory(
      FilePath.join(tempDir.path, 'Uppercase Comic'),
    ).create();
    await File(FilePath.join(comicDir.path, 'COVER.JPG')).writeAsBytes([1]);

    final comic = await const ImportComic().debugCheckSingleComic(comicDir);

    expect(comic, isNotNull);
    expect(comic!.cover, 'COVER.JPG');
  });

  test('local directory import uses first chapter image as cover', () async {
    final comicDir = await Directory(
      FilePath.join(tempDir.path, 'Chapter Only Comic'),
    ).create();
    final chapterDir = await Directory(
      FilePath.join(comicDir.path, 'chapter-1'),
    ).create();
    await File(FilePath.join(chapterDir.path, '001.JPG')).writeAsBytes([1]);

    final comic = await const ImportComic().debugCheckSingleComic(comicDir);

    expect(comic, isNotNull);
    expect(comic!.cover, FilePath.join('chapter-1', '001.JPG'));
    expect(comic.chapters?.ids, ['chapter-1']);
  });

  test('local directory import skips empty chapter directories', () async {
    final comicDir = await Directory(
      FilePath.join(tempDir.path, 'Sparse Chapter Comic'),
    ).create();
    await Directory(FilePath.join(comicDir.path, 'empty-chapter')).create();
    final chapterDir = await Directory(
      FilePath.join(comicDir.path, 'chapter-with-image'),
    ).create();
    await File(FilePath.join(chapterDir.path, '001.jpg')).writeAsBytes([1]);

    final comic = await const ImportComic().debugCheckSingleComic(comicDir);

    expect(comic, isNotNull);
    expect(comic!.cover, FilePath.join('chapter-with-image', '001.jpg'));
    expect(comic.chapters?.ids, ['chapter-with-image']);
    expect(comic.downloadedChapters, ['chapter-with-image']);
  });

  test('EhViewer category mapping tolerates malformed values', () {
    expect(safeEhViewerCategoryTag(0), isNull);
    expect(safeEhViewerCategoryTag(null), isNull);
    expect(safeEhViewerCategoryTag(1), 'MISC');
    expect(safeEhViewerCategoryTag('4'), 'MANGA');
    expect(safeEhViewerCategoryTag(512), 'WESTERN');
    expect(safeEhViewerCategoryTag(1024), isNull);
  });

  test('imported comic image extension detection is case insensitive', () {
    expect(isSupportedImportedComicImageExtension('JPG'), isTrue);
    expect(isSupportedImportedComicImageExtension('.PNG'), isTrue);
    expect(isSupportedImportedComicImageExtension('txt'), isFalse);
  });

  test(
    'import backup directory stays next to the destination directory',
    () async {
      final localRoot = await Directory(
        FilePath.join(tempDir.path, 'local-root'),
      ).create();
      final destination = await Directory(
        FilePath.join(localRoot.path, 'Comic'),
      ).create();
      await File(
        FilePath.join(destination.path, 'old.txt'),
      ).writeAsString('old');

      final backupPath = buildImportBackupDirectoryPath(destination);

      expect(backupPath, FilePath.join(localRoot.path, 'Comic_old'));
    },
  );

  test(
    'copy directories restores existing destination when copy fails',
    () async {
      final localRoot = await Directory(
        FilePath.join(tempDir.path, 'local-root'),
      ).create();
      final source = Directory(FilePath.join(tempDir.path, 'MissingComic'));
      final existingDestination = await Directory(
        FilePath.join(localRoot.path, 'MissingComic'),
      ).create();
      await File(
        FilePath.join(existingDestination.path, 'old.txt'),
      ).writeAsString('old');

      await expectLater(
        ImportComic.debugCopyDirectories({
          'toBeCopied': [source.path],
          'destination': localRoot.path,
        }),
        throwsA(isA<FileSystemException>()),
      );

      expect(
        await File(
          FilePath.join(existingDestination.path, 'old.txt'),
        ).readAsString(),
        'old',
      );
      expect(
        Directory(
          FilePath.join(localRoot.path, 'MissingComic_old'),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'copy directories keeps duplicate source basenames in one import batch',
    () async {
      final localRoot = await Directory(
        FilePath.join(tempDir.path, 'local-root'),
      ).create();
      final sourceRootA = await Directory(
        FilePath.join(tempDir.path, 'source-a'),
      ).create();
      final sourceRootB = await Directory(
        FilePath.join(tempDir.path, 'source-b'),
      ).create();
      final sourceA = await Directory(
        FilePath.join(sourceRootA.path, 'Comic'),
      ).create();
      final sourceB = await Directory(
        FilePath.join(sourceRootB.path, 'Comic'),
      ).create();
      await File(FilePath.join(sourceA.path, 'a.txt')).writeAsString('a');
      await File(FilePath.join(sourceB.path, 'b.txt')).writeAsString('b');

      final result = await ImportComic.debugCopyDirectories({
        'toBeCopied': [sourceA.path, sourceB.path],
        'destination': localRoot.path,
      });

      expect(result[sourceA.path], FilePath.join(localRoot.path, 'Comic'));
      expect(result[sourceB.path], FilePath.join(localRoot.path, 'Comic(1)'));
      expect(
        await File(
          FilePath.join(result[sourceA.path]!, 'a.txt'),
        ).readAsString(),
        'a',
      );
      expect(
        await File(
          FilePath.join(result[sourceB.path]!, 'b.txt'),
        ).readAsString(),
        'b',
      );
      expect(
        Directory(FilePath.join(localRoot.path, 'Comic_old')).existsSync(),
        isFalse,
      );
    },
  );
}
