import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/domain/comic_key.dart';
import 'package:venera/core/domain/local_comic_key.dart';

void main() {
  test(
    'AppDatabase initializes once and supports async transactions',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'venera_app_database_test_',
      );
      final database = AppDatabase(
        path: path.join(tempDirectory.path, AppDatabase.fileName),
      );
      addTearDown(() async {
        await database.close();
        await _deleteDirectoryWithRetry(tempDirectory);
      });

      await database.initialize();
      await database.initialize();
      await database.raw.writeTransaction((tx) async {
        await tx.execute(
          'INSERT INTO app_metadata(key, value, updated_at) VALUES(?, ?, ?)',
          ['test', 'value', 1],
        );
      });

      final row = await database.raw.get(
        'SELECT value FROM app_metadata WHERE key = ?',
        ['test'],
      );
      expect(row['value'], 'value');
    },
  );

  test('AppDatabase rejects access before initialization', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'venera_app_database_uninitialized_test_',
    );
    final database = AppDatabase(
      path: path.join(tempDirectory.path, AppDatabase.fileName),
    );
    addTearDown(() async {
      await database.close();
      await _deleteDirectoryWithRetry(tempDirectory);
    });

    expect(() => database.raw, throwsStateError);
  });

  test('AppDatabase keeps repository identity columns consistent', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'venera_app_database_identity_test_',
    );
    final database = AppDatabase(
      path: path.join(tempDirectory.path, AppDatabase.fileName),
    );
    addTearDown(() async {
      await database.close();
      await _deleteDirectoryWithRetry(tempDirectory);
    });
    await database.initialize();

    const original = LocalComicKey(comicType: 'local', comicId: 'old');
    const renamed = LocalComicKey(comicType: 'local', comicId: 'renamed');
    await database.raw.execute(
      '''
      INSERT INTO local_comics(
        identity_key, comic_id, comic_type, directory, payload_json
      ) VALUES (?, ?, ?, ?, ?)
      ''',
      [original.storageKey, original.comicId, original.comicType, 'old', '{}'],
    );
    await database.raw.execute(
      '''
      INSERT INTO local_archive_links(
        identity_key, comic_id, comic_type, directory, status, updated_at
      ) VALUES (?, ?, ?, ?, 'missing', 0)
      ''',
      [original.storageKey, original.comicId, original.comicType, 'old'],
    );

    await database.raw.execute(
      '''
      UPDATE local_comics
      SET identity_key = ?, comic_id = ?, directory = ?
      WHERE identity_key = ?
      ''',
      [renamed.storageKey, renamed.comicId, 'renamed', original.storageKey],
    );
    final archive = await database.raw.get(
      'SELECT identity_key, comic_id, directory FROM local_archive_links',
    );
    expect(archive['identity_key'], renamed.storageKey);
    expect(archive['comic_id'], renamed.comicId);
    expect(archive['directory'], 'renamed');

    const image = ComicKey(sourceKey: 'source', comicId: 'comic');
    await expectLater(
      database.raw.execute(
        '''
        INSERT INTO image_favorites(
          identity_key, source_key, comic_id, payload_json
        ) VALUES (?, ?, ?, '{}')
        ''',
        ['wrong-identity', image.sourceKey, image.comicId],
      ),
      throwsA(anything),
    );
    await database.raw.execute(
      '''
      INSERT INTO image_favorites(
        identity_key, source_key, comic_id, payload_json
      ) VALUES (?, ?, ?, '{}')
      ''',
      [image.storageKey, image.sourceKey, image.comicId],
    );
  });
}

Future<void> _deleteDirectoryWithRetry(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on PathAccessException {
      if (attempt == 4) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
