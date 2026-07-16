import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/local_archive.dart';
import 'package:venera/foundation/local_archive_catalog.dart';

void main() {
  late Directory root;
  late LocalComic comic;
  late LocalArchiveCatalog catalog;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-archive-catalog-');
    comic = LocalComic(
      id: 'comic-1',
      title: 'Comic',
      subtitle: '',
      tags: const [],
      directory: root.path,
      chapters: null,
      cover: 'cover.jpg',
      comicType: ComicType.local,
      downloadedChapters: const [],
      createdAt: DateTime(2026),
    );
    catalog = LocalArchiveCatalog.forTesting();
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('loose comic is detected without walking page files', () async {
    final chapter = await Directory(p.join(root.path, 'chapter')).create();
    await File(p.join(chapter.path, '1.jpg')).writeAsBytes([1, 2, 3]);

    final snapshot = await catalog.inspectFast(comic);

    expect(snapshot.state, LocalStorageState.loose);
    expect(snapshot.looseBytes, 0);
  });

  test(
    'fast inspection trusts manifest metadata and defers ZIP decoding',
    () async {
      final manifest = await _writeArchiveMetadata(root, comic);
      // Deliberately not a ZIP. Deep validation owns this check.
      await File(_archivePath(root)).writeAsBytes([1, 2, 3, 4]);

      final snapshot = await catalog.inspectFast(comic);

      expect(snapshot.state, LocalStorageState.archived);
      expect(snapshot.manifest?.identity, manifest.identity);
    },
  );

  test(
    'matching expanded marker is exposed as expanded internal state',
    () async {
      final manifest = await _writeArchiveMetadata(root, comic);
      await File(_archivePath(root)).writeAsBytes([1]);
      await File(
        p.join(_metadataPath(root), 'expanded.json'),
      ).writeAsString(jsonEncode({'archive': manifest.identity}));

      expect(
        (await catalog.inspectFast(comic)).state,
        LocalStorageState.expanded,
      );
    },
  );

  test(
    'fingerprint invalidates cached state when dirty marker appears',
    () async {
      await _writeArchiveMetadata(root, comic);
      await File(_archivePath(root)).writeAsBytes([1]);
      expect(
        (await catalog.inspectFast(comic)).state,
        LocalStorageState.archived,
      );
      expect(catalog.cachedEntryCount, 1);

      await File(p.join(_metadataPath(root), 'dirty')).writeAsString('1');

      expect((await catalog.inspectFast(comic)).state, LocalStorageState.dirty);
    },
  );

  test('incomplete metadata pair is reported as an error', () async {
    await Directory(_metadataPath(root)).create();
    await File(_archivePath(root)).writeAsBytes([1]);

    final snapshot = await catalog.inspectFast(comic);

    expect(snapshot.state, LocalStorageState.error);
    expect(snapshot.errorMessage, contains('Incomplete'));
  });
}

Future<ArchiveManifest> _writeArchiveMetadata(
  Directory root,
  LocalComic comic,
) async {
  final metadata = await Directory(_metadataPath(root)).create();
  final bytes = [1, 2, 3];
  final manifest = ArchiveManifest(
    version: ArchiveManifest.currentVersion,
    comicId: comic.id,
    sourceKey: comic.sourceKey,
    comicType: comic.comicType.value,
    createdAtMillis: 1,
    entries: [
      ArchiveManifestEntry(
        path: 'chapter/1.jpg',
        size: bytes.length,
        modifiedAtMillis: 1,
        sha256: sha256.convert(bytes).toString(),
      ),
    ],
  );
  await File(
    p.join(metadata.path, LocalArchiveService.manifestFileName),
  ).writeAsString(jsonEncode(manifest.toJson()));
  return manifest;
}

String _metadataPath(Directory root) =>
    p.join(root.path, LocalArchiveService.metadataDirectoryName);

String _archivePath(Directory root) =>
    p.join(_metadataPath(root), LocalArchiveService.archiveFileName);
