import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/domain/comic_key.dart';
import 'package:venera/core/domain/local_comic_key.dart';
import 'package:venera/core/repositories/domain_repositories.dart';
import 'package:venera/core/repositories/download_task_repository.dart';
import 'package:venera/core/repositories/favorites_repository.dart';
import 'package:venera/core/repositories/history_repository.dart';
import 'package:venera/core/repositories/local_library_repository.dart';
import 'package:venera/core/repositories/source_repository.dart';

void main() {
  late Directory directory;
  late AppDatabase database;
  late DomainRepositories repositories;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'venera_domain_repositories_',
    );
    database = AppDatabase(path: p.join(directory.path, AppDatabase.fileName));
    await database.initialize();
    repositories = DomainRepositories(database);
  });

  tearDown(() async {
    await database.close();
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await directory.delete(recursive: true);
        break;
      } on PathAccessException {
        if (attempt == 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  test('settings updates are atomic, observable and detached', () async {
    final changed = repositories.settings.watch().firstWhere(
      (value) => value['theme'] == 'dark' && value['reader'] == 'vertical',
    );

    await Future.wait([
      repositories.settings.setValue('theme', 'dark'),
      repositories.settings.setValue('reader', 'vertical'),
    ]);

    final settings = await changed;
    expect(settings, {'theme': 'dark', 'reader': 'vertical'});
    expect(() => settings['theme'] = 'light', throwsA(isA<UnsupportedError>()));

    await expectLater(
      repositories.settings.update((_) => throw StateError('rollback')),
      throwsStateError,
    );
    expect(await repositories.settings.read(), settings);
  });

  test(
    'history uses stable identities, batched writes and time ordering',
    () async {
      const olderKey = ComicKey(sourceKey: 'source@one', comicId: 'comic/1');
      const newerKey = ComicKey(sourceKey: 'source', comicId: 'one@comic/1');
      await repositories.history.upsertAll([
        HistoryRecord(key: olderKey, payload: {'time': 10, 'page': 2}),
        HistoryRecord(key: newerKey, payload: {'time': 20, 'page': 4}),
      ]);

      final records = await repositories.history.list();
      expect(records.map((record) => record.key), [newerKey, olderKey]);
      expect(
        (await repositories.history.get(olderKey))!.payload,
        containsPair('page', 2),
      );
      final raw = await database.raw.get(
        'SELECT payload_json FROM reading_history WHERE identity_key = ?',
        [olderKey.storageKey],
      );
      expect(raw['payload_json'], contains('"source_key":"source@one"'));
      final plan = await database.raw.getAll('''
        EXPLAIN QUERY PLAN
        SELECT * FROM reading_history
        ORDER BY
          CAST(json_extract(payload_json, '\$.time') AS INTEGER) DESC,
          identity_key
        LIMIT 60
        ''');
      expect(
        plan.map((row) => row['detail']).join(' '),
        contains('reading_history_time_index'),
      );

      await repositories.history.removeAll([olderKey, newerKey]);
      expect(await repositories.history.count(), 0);
    },
  );

  test(
    'favorites preserves arbitrary logical payloads and replaces atomically',
    () async {
      await repositories.favorites.replaceAll([
        FavoriteCollectionRecord(
          name: 'Shelf',
          payload: const [
            {'id': 'comic-1'},
          ],
        ),
        FavoriteCollectionRecord(name: 'folder_order', payload: 'Shelf'),
      ]);

      expect(await repositories.favorites.list(), hasLength(2));
      expect(
        (await repositories.favorites.get('folder_order'))!.payload,
        'Shelf',
      );

      await expectLater(
        repositories.favorites.replaceAll([
          FavoriteCollectionRecord(name: 'Shelf', payload: const []),
          FavoriteCollectionRecord(name: 'Shelf', payload: const []),
        ]),
        throwsArgumentError,
      );
      expect(await repositories.favorites.list(), hasLength(2));
    },
  );

  test(
    'local library keeps archive links consistent with comic identity',
    () async {
      const key = LocalComicKey(comicType: '42', comicId: 'local-1');
      await repositories.localLibrary.upsertComic(
        LocalComicRecord(
          key: key,
          directory: 'local-1',
          payload: const {'title': 'Local Comic'},
        ),
      );
      await repositories.localLibrary.upsertArchiveLink(
        const LocalArchiveLinkRecord(
          key: key,
          directory: 'local-1',
          originalRoot: r'D:\Comics',
          relativePath: r'local-1\.venera\archive.zip',
          originalPath: null,
          expectedLength: 123,
          resolvedPath: r'D:\Comics\local-1\.venera\archive.zip',
          status: LocalArchiveLinkStatus.available,
          updatedAtMillis: 100,
        ),
      );

      final entry = await repositories.localLibrary.get(key);
      expect(entry!.comic.payload['title'], 'Local Comic');
      expect(entry.archive!.status, LocalArchiveLinkStatus.available);
      await repositories.localLibrary.upsertComic(
        LocalComicRecord(
          key: key,
          directory: 'local-renamed',
          payload: const {'title': 'Local Comic'},
        ),
      );
      expect(
        (await repositories.localLibrary.get(key))!.archive!.directory,
        'local-renamed',
      );
      expect(
        await repositories.localLibrary.list(
          archiveStatus: LocalArchiveLinkStatus.missing,
        ),
        isEmpty,
      );

      await repositories.localLibrary.remove(key);
      expect(await repositories.localLibrary.get(key), isNull);
      expect(
        await database.raw.getAll('SELECT * FROM local_archive_links'),
        isEmpty,
      );
      await expectLater(
        database.raw.execute(
          '''
          INSERT INTO local_archive_links(
            identity_key, comic_id, comic_type, directory, status, updated_at
          ) VALUES (?, ?, ?, ?, 'missing', 1)
          ''',
          [key.storageKey, key.comicId, key.comicType, 'orphan'],
        ),
        throwsA(anything),
      );
    },
  );

  test(
    'download tasks persist progress and recover interrupted work',
    () async {
      const comicKey = ComicKey(sourceKey: 'source', comicId: 'comic');
      final repository = SqliteDownloadTaskRepository(
        database,
        clock: () => DateTime.fromMillisecondsSinceEpoch(100, isUtc: true),
      );
      await repository.upsert(
        DownloadTaskRecord(
          id: 'task-1',
          comicKey: comicKey,
          chapterId: 'chapter-1',
          state: DownloadTaskState.running,
          completedUnits: 1,
          totalUnits: 10,
          payload: const {'title': 'Chapter 1'},
          createdAtMillis: 100,
          updatedAtMillis: 100,
        ),
      );

      expect(await repository.recoverInterrupted(), 1);
      expect((await repository.get('task-1'))!.state, DownloadTaskState.queued);
      expect(await repository.list(states: const {}), isEmpty);
      final progressed = await repository.updateProgress(
        'task-1',
        completedUnits: 5,
        totalUnits: 10,
      );
      expect(progressed.fraction, 0.5);
      await repository.updateState('task-1', DownloadTaskState.completed);
      expect(await repository.clearTerminal(), 1);
      expect(await repository.get('task-1'), isNull);
    },
  );

  test(
    'source documents validate content integrity and availability',
    () async {
      final available = SourceDocument.available(
        name: 'source.js',
        content: const [1, 2, 3],
      );
      final missing = SourceDocument.missing(
        name: 'missing.js',
        sha256: SourceDocument.digestBytes(const [4, 5]),
        expectedLength: 2,
      );
      await repositories.sources.replaceAll([available, missing]);

      final restored = (await repositories.sources.get('source.js'))!;
      expect(restored.content, [1, 2, 3]);
      expect(() => restored.content![0] = 9, throwsUnsupportedError);
      expect(
        (await repositories.sources.list(available: false)).single.name,
        'missing.js',
      );
      expect(
        () => SourceDocument.available(name: '../source.js', content: const []),
        throwsArgumentError,
      );
    },
  );
}
