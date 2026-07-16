import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/local_archive.dart';

import 'test_native_paths.dart';

void main() {
  late Directory library;
  late Directory comicDirectory;
  late Directory zipDllDirectory;
  late LocalComic comic;
  String? originalCurrentDirectory;

  setUpAll(() async {
    final source = File(zipDllSourcePath);
    if (!source.existsSync()) {
      throw StateError('Missing test zip dll at $zipDllSourcePath');
    }
    originalCurrentDirectory = Directory.current.path;
    // Windows keeps a loaded DLL locked until the test process exits. Reuse
    // the stable build output instead of copying it into a temporary folder
    // that cannot be removed in tearDownAll.
    zipDllDirectory = source.parent;
    Directory.current = zipDllDirectory.path;
  });

  tearDownAll(() async {
    if (originalCurrentDirectory != null) {
      Directory.current = originalCurrentDirectory!;
    }
  });

  setUp(() async {
    library = await Directory.systemTemp.createTemp('venera-local-library-');
    comicDirectory = await Directory(
      '${library.path}${Platform.pathSeparator}comic-a',
    ).create();
    await File(
      '${comicDirectory.path}${Platform.pathSeparator}cover.jpg',
    ).writeAsBytes([9, 8, 7]);
    final chapter = await Directory(
      '${comicDirectory.path}${Platform.pathSeparator}chapter-1',
    ).create();
    await File(
      '${chapter.path}${Platform.pathSeparator}1.jpg',
    ).writeAsBytes(List<int>.generate(4096, (index) => index % 251));
    await File(
      '${chapter.path}${Platform.pathSeparator}2.jpg',
    ).writeAsBytes(List<int>.generate(2048, (index) => (index * 3) % 251));
    comic = LocalComic(
      id: 'comic-a',
      title: 'Comic A',
      subtitle: 'Author',
      tags: const ['tag'],
      directory: comicDirectory.path,
      chapters: null,
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: const [],
      createdAt: DateTime(2026, 7, 16),
    );
  });

  tearDown(() async {
    if (await library.exists()) {
      await library.delete(recursive: true);
    }
  });

  test('archive entry path validation rejects traversal and ambiguity', () {
    expect(normalizeLocalArchiveEntryPath('chapter/1.jpg'), 'chapter/1.jpg');
    for (final unsafe in [
      '../outside.jpg',
      'chapter/../outside.jpg',
      '/absolute.jpg',
      r'C:/absolute.jpg',
      r'chapter\1.jpg',
      'chapter//1.jpg',
    ]) {
      expect(
        () => normalizeLocalArchiveEntryPath(unsafe),
        throwsFormatException,
        reason: unsafe,
      );
    }
  });

  test('manifest rejects case-conflicting and malformed entries', () {
    Map<String, Object> entry(String path) => {
      'path': path,
      'size': 1,
      'modifiedAt': 1,
      'sha256': List.filled(64, 'a').join(),
    };
    final json = <String, Object>{
      'version': ArchiveManifest.currentVersion,
      'comic': {'id': 'id', 'sourceKey': 'local', 'comicType': 0},
      'createdAt': 1,
      'entries': [entry('A.jpg'), entry('a.jpg')],
    };
    expect(() => ArchiveManifest.fromJson(json), throwsFormatException);
  });

  test(
    'compress keeps cover, validates archive, and removes loose pages',
    () async {
      final service = LocalArchiveService.forTesting(libraryRoot: library.path);

      final result = await service.compress(comic);

      expect(result.state, LocalStorageState.archived);
      expect(result.rebuiltArchive, isTrue);
      expect(comic.coverFile.existsSync(), isTrue);
      expect(
        File(
          '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}1.jpg',
        ).existsSync(),
        isFalse,
      );
      expect(service.archiveFileFor(comic).existsSync(), isTrue);
      expect(service.manifestFileFor(comic).existsSync(), isTrue);
      expect(result.manifest?.entries.map((entry) => entry.path), [
        'chapter-1/1.jpg',
        'chapter-1/2.jpg',
      ]);
    },
  );

  test(
    'restore retains ZIP and repeat compression only cleans expansion',
    () async {
      final service = LocalArchiveService.forTesting(libraryRoot: library.path);
      await service.compress(comic);
      final archive = service.archiveFileFor(comic);
      final archiveBefore = await archive.readAsBytes();
      final manifestBefore = await service
          .manifestFileFor(comic)
          .readAsString();

      final restored = await service.restore(comic);

      expect(restored.state, LocalStorageState.expanded);
      expect(archive.existsSync(), isTrue);
      expect(
        File(
          '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}1.jpg',
        ).existsSync(),
        isTrue,
      );

      final recompressed = await service.compress(comic);

      expect(recompressed.state, LocalStorageState.archived);
      expect(recompressed.rebuiltArchive, isFalse);
      expect(await archive.readAsBytes(), archiveBefore);
      expect(
        await service.manifestFileFor(comic).readAsString(),
        manifestBefore,
      );
    },
  );

  test('compression and opening report live progress stages', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    final compressionProgress = <LocalArchiveProgress>[];

    await service.compress(comic, onProgress: compressionProgress.add);

    expect(
      compressionProgress.map((value) => value.operation),
      containsAll([
        LocalArchiveOperation.inspect,
        LocalArchiveOperation.compress,
        LocalArchiveOperation.verify,
        LocalArchiveOperation.reconcile,
        LocalArchiveOperation.cleanup,
      ]),
    );
    expect(
      compressionProgress
          .where((value) => value.operation == LocalArchiveOperation.compress)
          .last
          .fraction,
      1,
    );

    final openingProgress = <LocalArchiveProgress>[];
    await service.restore(comic, onProgress: openingProgress.add);

    expect(
      openingProgress.map((value) => value.operation),
      containsAll([
        LocalArchiveOperation.restore,
        LocalArchiveOperation.finalize,
      ]),
    );
    expect(openingProgress.last.fraction, 1);
  });

  test('compression and opening can cancel from live progress', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    final compressionToken = LocalArchiveCancellationToken();

    await expectLater(
      service.compress(
        comic,
        cancellationToken: compressionToken,
        onProgress: (progress) {
          if (progress.operation == LocalArchiveOperation.compress) {
            compressionToken.cancel();
          }
        },
      ),
      throwsA(isA<LocalArchiveCancelledException>()),
    );
    expect(service.archiveFileFor(comic).existsSync(), isFalse);
    expect(
      File(
        '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}1.jpg',
      ).existsSync(),
      isTrue,
    );

    await service.compress(comic);
    final openingToken = LocalArchiveCancellationToken();
    await expectLater(
      service.restore(
        comic,
        cancellationToken: openingToken,
        onProgress: (progress) {
          if (progress.operation == LocalArchiveOperation.restore) {
            openingToken.cancel();
          }
        },
      ),
      throwsA(isA<LocalArchiveCancelledException>()),
    );
    expect(service.archiveFileFor(comic).existsSync(), isTrue);
    expect(
      File(
        '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}1.jpg',
      ).existsSync(),
      isFalse,
    );
  });

  test('dirty expanded content rebuilds and survives another restore', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    await service.compress(comic);
    await service.restore(comic);
    await service.markDirty(comic);
    final changed = File(
      '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}1.jpg',
    );
    final changedBytes = utf8.encode('new downloaded page bytes');
    await changed.writeAsBytes(changedBytes, flush: true);

    final rebuilt = await service.compress(comic);
    expect(rebuilt.rebuiltArchive, isTrue);
    expect(rebuilt.state, LocalStorageState.archived);

    await service.restore(comic);
    expect(await changed.readAsBytes(), changedBytes);
    expect(service.archiveFileFor(comic).existsSync(), isTrue);
  });

  test(
    'marker-free loose edits retain chapters that only exist in the ZIP',
    () async {
      final service = LocalArchiveService.forTesting(libraryRoot: library.path);
      await service.compress(comic);
      final originalPage = File(
        '${comicDirectory.path}${Platform.pathSeparator}chapter-1'
        '${Platform.pathSeparator}1.jpg',
      );
      expect(originalPage.existsSync(), isFalse);

      // Simulate an external copy that cannot call prepareForWrite/markDirty.
      final externalChapter = await Directory(
        '${comicDirectory.path}${Platform.pathSeparator}chapter-2',
      ).create();
      final externalPage = File(
        '${externalChapter.path}${Platform.pathSeparator}1.jpg',
      );
      const externalBytes = <int>[4, 3, 2, 1];
      await externalPage.writeAsBytes(externalBytes, flush: true);

      final rebuilt = await service.compress(comic);
      expect(rebuilt.rebuiltArchive, isTrue);
      await service.restore(comic);

      expect(originalPage.existsSync(), isTrue);
      expect(await externalPage.readAsBytes(), externalBytes);
    },
  );

  test('prepareForWrite restores and marks the loose tree dirty', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    await service.compress(comic);
    final page = File(
      '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}1.jpg',
    );
    expect(page.existsSync(), isFalse);

    final prepared = await service.prepareForWrite(comic);

    expect(page.existsSync(), isTrue);
    expect(prepared.state, LocalStorageState.dirty);
    expect(service.archiveFileFor(comic).existsSync(), isTrue);
  });

  test('prepared deletion is preserved by recompression and restore', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    await service.compress(comic);
    final deletedPage = File(
      '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}1.jpg',
    );
    final retainedPage = File(
      '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}2.jpg',
    );

    await service.runPreparedMutation(comic, () => deletedPage.delete());
    await service.compress(comic);
    await service.restore(comic);

    expect(deletedPage.existsSync(), isFalse);
    expect(retainedPage.existsSync(), isTrue);
  });

  test('manager deletes a chapter after restoring an archived comic', () async {
    final dataDirectory = await Directory(
      '${library.path}${Platform.pathSeparator}data',
    ).create();
    App.dataPath = dataDirectory.path;
    await File(
      '${dataDirectory.path}${Platform.pathSeparator}local_path',
    ).writeAsString(library.path);
    LocalManager.debugResetInstance();
    final manager = LocalManager();
    await manager.init();
    addTearDown(() async {
      manager.dispose();
      LocalManager.debugResetInstance();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    final secondChapter = await Directory(
      '${comicDirectory.path}${Platform.pathSeparator}chapter-2',
    ).create();
    final retainedPage = File(
      '${secondChapter.path}${Platform.pathSeparator}1.jpg',
    );
    await retainedPage.writeAsBytes(const [7, 6, 5, 4]);
    final managedComic = LocalComic(
      id: comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      tags: comic.tags,
      directory: comic.directory,
      chapters: comic.chapters,
      cover: comic.cover,
      comicType: comic.comicType,
      downloadedChapters: const ['chapter-1', 'chapter-2'],
      createdAt: comic.createdAt,
    );
    await manager.add(managedComic);
    final service = LocalArchiveService();
    await service.compress(managedComic);
    final deletedPage = File(
      '${comicDirectory.path}${Platform.pathSeparator}chapter-1'
      '${Platform.pathSeparator}1.jpg',
    );
    expect(deletedPage.existsSync(), isFalse);

    await manager.deleteComicChapters(managedComic, const ['chapter-1']);
    final updated = manager.find(managedComic.id, managedComic.comicType);
    expect(updated?.downloadedChapters, const ['chapter-2']);

    await service.compress(managedComic);
    await service.restore(managedComic);
    expect(deletedPage.existsSync(), isFalse);
    expect(retainedPage.existsSync(), isTrue);
  });

  test('compression waits for an active writer lease', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    await service.compress(comic);
    final lease = await service.beginWrite(comic);
    final addedPage = File(
      '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}3.jpg',
    );
    await addedPage.writeAsBytes(utf8.encode('late downloaded page'));
    var completed = false;
    final compression = service.compress(comic).then((value) {
      completed = true;
      return value;
    });

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse);
    lease.close();
    await compression;
    await service.restore(comic);

    expect(await addedPage.readAsString(), 'late downloaded page');
  });

  test('waiting compression remains cancellable', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    final lease = await service.beginWrite(comic);
    final token = LocalArchiveCancellationToken();
    final compression = service.compress(comic, cancellationToken: token);
    token.cancel();

    await expectLater(
      compression,
      throwsA(isA<LocalArchiveCancelledException>()),
    );
    lease.close();
  });

  test('inspect recovers an interrupted archive pair commit', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    await service.compress(comic);
    final archive = service.archiveFileFor(comic);
    final manifest = service.manifestFileFor(comic);
    await archive.rename('${archive.path}.bak');
    await manifest.rename('${manifest.path}.bak');

    final recovered = await service.inspect(comic);

    expect(recovered.state, LocalStorageState.archived);
    expect(archive.existsSync(), isTrue);
    expect(manifest.existsSync(), isTrue);
  });

  test(
    'inspect completes a first commit left with a temporary manifest',
    () async {
      final service = LocalArchiveService.forTesting(libraryRoot: library.path);
      await service.compress(comic);
      final archive = service.archiveFileFor(comic);
      final manifest = service.manifestFileFor(comic);
      final temporaryManifest = File('${manifest.path}.tmp-interrupted');
      await manifest.rename(temporaryManifest.path);

      final recovered = await service.inspect(comic);

      expect(recovered.state, LocalStorageState.archived);
      expect(archive.existsSync(), isTrue);
      expect(manifest.existsSync(), isTrue);
      expect(temporaryManifest.existsSync(), isFalse);
    },
  );

  test('unsafe manifest blocks restore before extraction', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    await service.compress(comic);
    final manifestFile = service.manifestFileFor(comic);
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final entries = manifest['entries'] as List<dynamic>;
    (entries.first as Map<String, dynamic>)['path'] = '../outside.jpg';
    await manifestFile.writeAsString(jsonEncode(manifest), encoding: utf8);
    final outside = File('${library.path}${Platform.pathSeparator}outside.jpg');

    final snapshot = await service.inspect(comic);

    expect(snapshot.state, LocalStorageState.error);
    await expectLater(
      service.restore(comic),
      throwsA(isA<LocalArchiveException>()),
    );
    expect(outside.existsSync(), isFalse);
    expect(service.archiveFileFor(comic).existsSync(), isTrue);
  });

  test('comic paths outside the managed library are refused', () async {
    final outsideRoot = await Directory.systemTemp.createTemp(
      'venera-outside-comic-',
    );
    addTearDown(() => outsideRoot.delete(recursive: true));
    final outsideComic = LocalComic(
      id: comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      tags: comic.tags,
      directory: outsideRoot.path,
      chapters: comic.chapters,
      cover: comic.cover,
      comicType: comic.comicType,
      downloadedChapters: comic.downloadedChapters,
      createdAt: comic.createdAt,
    );
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);

    final snapshot = await service.inspect(outsideComic);
    expect(snapshot.state, LocalStorageState.error);
    await expectLater(
      service.compress(outsideComic),
      throwsA(isA<LocalArchiveException>()),
    );
  });

  test('pre-cancelled compression leaves all source files untouched', () async {
    final service = LocalArchiveService.forTesting(libraryRoot: library.path);
    final token = LocalArchiveCancellationToken()..cancel();
    final page = File(
      '${comicDirectory.path}${Platform.pathSeparator}chapter-1${Platform.pathSeparator}1.jpg',
    );

    await expectLater(
      service.compress(comic, cancellationToken: token),
      throwsA(isA<LocalArchiveCancelledException>()),
    );

    expect(page.existsSync(), isTrue);
    expect(service.archiveFileFor(comic).existsSync(), isFalse);
  });

  test(
    'streaming writer archives 85 comics with unicode paths',
    () async {
      final service = LocalArchiveService.forTesting(libraryRoot: library.path);
      for (var index = 0; index < 85; index++) {
        final root = await Directory(
          '${library.path}${Platform.pathSeparator}漫画-$index',
        ).create();
        await File(
          '${root.path}${Platform.pathSeparator}封面.jpg',
        ).writeAsBytes(const [1, 2, 3]);
        final chapter = await Directory(
          '${root.path}${Platform.pathSeparator}章节-$index',
        ).create();
        await File(
          '${chapter.path}${Platform.pathSeparator}页面-$index.jpg',
        ).writeAsBytes(List<int>.generate(64, (value) => value));
        final batchComic = LocalComic(
          id: '批量-$index',
          title: '漫画 $index',
          subtitle: '',
          tags: const [],
          directory: root.path,
          chapters: null,
          cover: '封面.jpg',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime(2026, 7, 16),
        );

        final result = await service.compress(batchComic);
        expect(result.state, LocalStorageState.archived, reason: '$index');
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
