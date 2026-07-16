import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalManager manager;
  late LocalFavoritesManager favorites;
  late Database favoritesDb;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-import-comic-');
    App.dataPath = tempDir.path;
    LocalManager.debugResetInstance();
    manager = LocalManager();
    await manager.init();
    favoritesDb = sqlite3.openInMemory();
    favoritesDb.execute('''
      create table folder_order (
        folder_name text primary key,
        order_value int
      );
      create table folder_sync (
        folder_name text primary key,
        source_key text,
        source_folder text
      );
    ''');
    favorites = LocalFavoritesManager();
    favorites.debugUseDatabaseForTest(favoritesDb, needsTagBackfill: false);
  });

  tearDown(() async {
    await manager.flushCurrentDownloadingTasks();
    manager.dispose();
    LocalManager.debugResetInstance();
    favoritesDb.close();
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

  test(
    'comic registration rolls back metadata, favorites, and managed files',
    () async {
      favorites.createFolder('Good');
      final firstDirectory = await Directory(
        FilePath.join(manager.path, 'first-managed'),
      ).create();
      final secondDirectory = await Directory(
        FilePath.join(manager.path, 'second-managed'),
      ).create();
      final now = DateTime.now();
      final first = LocalComic(
        id: 'source-first',
        title: 'First',
        subtitle: '',
        tags: const [],
        directory: firstDirectory.name,
        chapters: null,
        cover: '',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: now,
      );
      final second = LocalComic(
        id: 'source-second',
        title: 'Second',
        subtitle: '',
        tags: const [],
        directory: secondDirectory.name,
        chapters: null,
        cover: '',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: now,
      );

      final result = await const ImportComic().registerComics(
        {
          'Good': [first],
          'Missing': [second],
        },
        false,
        cleanupManagedDirectoriesOnFailure: true,
      );

      expect(result, isFalse);
      expect(manager.getComics(LocalSortType.timeDesc), isEmpty);
      expect(favorites.getFolderComics('Good'), isEmpty);
      expect(await firstDirectory.exists(), isFalse);
      expect(await secondDirectory.exists(), isFalse);
    },
  );

  test(
    'failed external directory registration never deletes user files',
    () async {
      final externalDirectory = await Directory(
        FilePath.join(tempDir.path, 'external-comic'),
      ).create();
      final marker = await File(
        FilePath.join(externalDirectory.path, 'page.jpg'),
      ).writeAsBytes([1, 2, 3]);
      final comic = LocalComic(
        id: 'external',
        title: 'External',
        subtitle: '',
        tags: const [],
        directory: externalDirectory.path,
        chapters: null,
        cover: marker.name,
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.now(),
      );

      final result = await const ImportComic().registerComics({
        'Missing': [comic],
      }, false);

      expect(result, isFalse);
      expect(manager.getComics(LocalSortType.timeDesc), isEmpty);
      expect(await marker.exists(), isTrue);
    },
  );
}
