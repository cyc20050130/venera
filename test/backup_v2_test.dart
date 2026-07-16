import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/backup_v2.dart';
import 'package:venera/utils/data.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-backup-v2-');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('logical backup is versioned and independent from database files', () {
    File('${tempDir.path}/appdata.json').writeAsStringSync(
      jsonEncode({
        'settings': {'theme_mode': 'dark'},
        'searchHistory': ['query'],
      }),
    );
    final history = sqlite3.open('${tempDir.path}/history.db');
    history.execute('''
      CREATE TABLE history(
        id TEXT, source_key TEXT, ep INTEGER, page INTEGER, chapter_group INTEGER
      );
    ''');
    history.execute('INSERT INTO history VALUES (?, ?, ?, ?, ?);', [
      'comic',
      'source',
      3,
      12,
      2,
    ]);
    history.execute('''
      CREATE TABLE image_favorites(
        id TEXT, source_key TEXT, image_favorites_ep TEXT
      );
    ''');
    history.execute('INSERT INTO image_favorites VALUES (?, ?, ?);', [
      'comic',
      'source',
      '[{"ep":3,"imageFavorites":[{"page":12}]}]',
    ]);
    history.close();

    final cookies = sqlite3.open('${tempDir.path}/cookie.db');
    cookies.execute('''
      CREATE TABLE cookies(
        name TEXT, value TEXT, domain TEXT, path TEXT, expires INTEGER,
        secure INTEGER, httpOnly INTEGER
      );
    ''');
    cookies.execute('INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?);', [
      'session',
      'secret',
      'example.test',
      '/',
      null,
      1,
      1,
    ]);
    cookies.close();
    File('${tempDir.path}/downloading_tasks.json').writeAsStringSync(
      jsonEncode([
        {
          'type': 'ImagesDownloadTask',
          'source': 'source',
          'comicId': 'comic',
          'downloadedCount': 2,
          'totalCount': 10,
        },
      ]),
    );

    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
    );

    expect(payload.manifest.appVersion, 'test');
    expect(payload.manifest.isFullBackup, isTrue);
    expect(payload.manifest.isCompleteRewriteBackup, isTrue);
    expect(payload.entries, contains('$backupLogicalDirectory/history.json'));
    expect(verifyBackupV2Payload(payload.manifest, payload.entries), isTrue);
    final decoded =
        jsonDecode(
              utf8.decode(
                payload.entries['$backupLogicalDirectory/history.json']!,
              ),
            )
            as List;
    expect(decoded.single['source_key'], 'source');
    expect(decoded.single['page'], 12);

    final imageFavorites =
        jsonDecode(
              utf8.decode(
                payload
                    .entries['$backupLogicalDirectory/image_favorites.json']!,
              ),
            )
            as List;
    expect(imageFavorites.single['id'], 'comic');
    expect(imageFavorites.single['source_key'], 'source');

    final cookieRows =
        jsonDecode(
              utf8.decode(
                payload.entries['$backupLogicalDirectory/cookies.json']!,
              ),
            )
            as List;
    expect(cookieRows.single, containsPair('name', 'session'));
    expect(cookieRows.single, containsPair('httpOnly', 1));

    final downloadTasks =
        jsonDecode(
              utf8.decode(
                payload.entries['$backupLogicalDirectory/download_tasks.json']!,
              ),
            )
            as List;
    expect(downloadTasks.single, containsPair('comicId', 'comic'));
  });

  test('malformed optional download snapshot becomes an empty list', () {
    File(
      '${tempDir.path}/downloading_tasks.json',
    ).writeAsStringSync('{"not":"a list"}');

    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
    );

    expect(
      jsonDecode(
        utf8.decode(
          payload.entries['$backupLogicalDirectory/download_tasks.json']!,
        ),
      ),
      isEmpty,
    );
  });

  test('strict backup rejects malformed persisted data', () {
    File(
      '${tempDir.path}/downloading_tasks.json',
    ).writeAsStringSync('{"not":"a list"}');

    expect(
      () => buildBackupV2Payload(
        dataPath: tempDir.path,
        appVersion: 'test',
        strict: true,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('strict backup accepts missing optional legacy database tables', () {
    final history = sqlite3.open('${tempDir.path}/history.db');
    history.execute('''
      CREATE TABLE history(
        id TEXT, source_key TEXT, ep INTEGER, page INTEGER, chapter_group INTEGER
      );
    ''');
    history.close();

    final cookies = sqlite3.open('${tempDir.path}/cookie.db');
    cookies.execute('CREATE TABLE legacy_metadata(value TEXT);');
    cookies.close();

    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
      strict: true,
    );

    expect(
      jsonDecode(
        utf8.decode(
          payload.entries['$backupLogicalDirectory/image_favorites.json']!,
        ),
      ),
      isEmpty,
    );
    expect(
      jsonDecode(
        utf8.decode(payload.entries['$backupLogicalDirectory/cookies.json']!),
      ),
      isEmpty,
    );
  });

  test('strict backup still rejects a corrupted optional database', () {
    File('${tempDir.path}/cookie.db').writeAsStringSync('not a sqlite file');

    expect(
      () => buildBackupV2Payload(
        dataPath: tempDir.path,
        appVersion: 'test',
        strict: true,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('legacy history schema is normalized before rewrite validation', () {
    final history = sqlite3.open('${tempDir.path}/history.db');
    history.execute('''
      CREATE TABLE history_legacy(
        id TEXT, title TEXT, type INTEGER, ep INTEGER, page INTEGER
      );
    ''');
    history.execute('INSERT INTO history_legacy VALUES (?, ?, ?, ?, ?);', [
      'legacy-local',
      'Legacy local comic',
      0,
      2,
      9,
    ]);
    history.close();

    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
      strict: true,
    );
    final rows =
        jsonDecode(
              utf8.decode(
                payload.entries['$backupLogicalDirectory/history.json']!,
              ),
            )
            as List;

    expect(rows.single['id'], 'legacy-local');
    expect(rows.single['source_key'], 'local');
    expect(payload.manifest.isCompleteRewriteBackup, isTrue);
  });

  test('explicit local root is recorded for platform default libraries', () {
    final platformRoot = '${tempDir.path}/platform-local';

    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
      localRoot: platformRoot,
    );
    final localIndex =
        jsonDecode(
              utf8.decode(
                payload.entries['$backupLogicalDirectory/local_index.json']!,
              ),
            )
            as Map;

    expect(localIndex['localRoot'], platformRoot);
  });

  test('sync export uses the filtered appdata snapshot', () {
    File('${tempDir.path}/appdata.json').writeAsStringSync(
      jsonEncode({
        'settings': {'private': 'full'},
      }),
    );
    File('${tempDir.path}/syncdata.json').writeAsStringSync(
      jsonEncode({
        'settings': {'safe': 'filtered'},
      }),
    );

    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
      useSyncAppdata: true,
    );
    final decoded = jsonDecode(
      utf8.decode(payload.entries['$backupLogicalDirectory/appdata.json']!),
    );

    expect(decoded, {
      'settings': {'safe': 'filtered'},
    });
    expect(payload.manifest.isFullBackup, isFalse);
    expect(payload.manifest.isCompleteRewriteBackup, isFalse);
  });

  test('sync export keeps appdata when no filtered snapshot is needed', () {
    File('${tempDir.path}/appdata.json').writeAsStringSync(
      jsonEncode({
        'settings': {'theme': 'dark'},
      }),
    );

    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
      useSyncAppdata: true,
    );
    final decoded = jsonDecode(
      utf8.decode(payload.entries['$backupLogicalDirectory/appdata.json']!),
    );

    expect(decoded, {
      'settings': {'theme': 'dark'},
    });
  });

  test('manifest rejects malformed versions and entries', () {
    expect(
      BackupManifestV2.tryParse({
        'format': 'venera-backup',
        'version': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'entries': const [],
      }),
      isNull,
    );

    final legacyV2 = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
    ).manifest.toJson()..remove('scope');
    expect(BackupManifestV2.tryParse(legacyV2)?.isFullBackup, isFalse);

    final digest = List<String>.filled(64, '0').join();
    expect(
      BackupManifestV2.tryParse({
        'format': 'venera-backup',
        'version': currentBackupFormatVersion,
        'createdAt': DateTime.now().toIso8601String(),
        'scope': 'sync',
        'entries': [
          {'path': 'a', 'length': 0, 'sha256': digest, 'kind': 'test'},
          {'path': 'a/b', 'length': 0, 'sha256': digest, 'kind': 'test'},
        ],
      }),
      isNull,
    );
  });

  test('complete rewrite validation rejects sync-scoped backups', () {
    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
      useSyncAppdata: true,
    );
    for (final entry in payload.entries.entries) {
      File('${tempDir.path}/${entry.key}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(entry.value);
    }
    File(
      '${tempDir.path}/$backupManifestEntryName',
    ).writeAsStringSync(jsonEncode(payload.manifest.toJson()));

    expect(
      () => validateCompleteExtractedBackupV2(tempDir),
      throwsA(isA<FormatException>()),
    );
  });

  test('extracted V2 backup validates checksums', () {
    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
    );
    for (final entry in payload.entries.entries) {
      final file = File('${tempDir.path}/${entry.key}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(entry.value);
      expect(file.existsSync(), isTrue);
    }
    File(
      '${tempDir.path}/$backupManifestEntryName',
    ).writeAsStringSync(jsonEncode(payload.manifest.toJson()));
    expect(validateExtractedBackupV2(tempDir), isNotNull);

    final first = payload.entries.keys.first;
    File('${tempDir.path}/$first').writeAsStringSync('tampered');
    expect(
      () => validateExtractedBackupV2(tempDir),
      throwsA(isA<FormatException>()),
    );
  });

  test('compatibility files are covered by the V2 manifest', () {
    final logical = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
    );
    final payload = extendBackupV2Payload(logical, {
      'history.db': Uint8List.fromList([1, 2, 3]),
    });
    for (final entry in payload.entries.entries) {
      File('${tempDir.path}/${entry.key}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(entry.value);
    }
    File(
      '${tempDir.path}/$backupManifestEntryName',
    ).writeAsStringSync(jsonEncode(payload.manifest.toJson()));

    expect(validateExtractedBackupV2(tempDir), isNotNull);
    File('${tempDir.path}/history.db').writeAsBytesSync([9]);
    expect(
      () => validateExtractedBackupV2(tempDir),
      throwsA(isA<FormatException>()),
    );
  });

  test('scoped V2 backup rejects files outside its manifest', () {
    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
    );
    for (final entry in payload.entries.entries) {
      File('${tempDir.path}/${entry.key}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(entry.value);
    }
    File(
      '${tempDir.path}/$backupManifestEntryName',
    ).writeAsStringSync(jsonEncode(payload.manifest.toJson()));
    File('${tempDir.path}/cookie.db').writeAsBytesSync([1, 2, 3]);

    expect(
      () => validateExtractedBackupV2(tempDir),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Unmanifested backup entry'),
        ),
      ),
    );
  });

  test('early V2 backup keeps accepting legacy compatibility files', () {
    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
    );
    for (final entry in payload.entries.entries) {
      File('${tempDir.path}/${entry.key}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(entry.value);
    }
    final legacyManifest = payload.manifest.toJson()..remove('scope');
    File(
      '${tempDir.path}/$backupManifestEntryName',
    ).writeAsStringSync(jsonEncode(legacyManifest));
    File('${tempDir.path}/history.db').writeAsBytesSync([1, 2, 3]);

    final parsed = validateExtractedBackupV2(tempDir);
    expect(parsed, isNotNull);
    expect(parsed!.hasExplicitScope, isFalse);
    expect(parsed.isFullBackup, isFalse);
  });

  test('archive entry normalization rejects traversal and absolute paths', () {
    expect(normalizeDataArchiveEntryName('../history.db'), isNull);
    expect(normalizeDataArchiveEntryName(r'C:\history.db'), isNull);
    expect(normalizeDataArchiveEntryName('/history.db'), isNull);
    expect(normalizeDataArchiveEntryName('history.db:payload'), isNull);
    expect(normalizeDataArchiveEntryName('history.db.'), isNull);
    expect(normalizeDataArchiveEntryName('history.db '), isNull);
    expect(normalizeDataArchiveEntryName('CON'), isNull);
    expect(normalizeDataArchiveEntryName('aux.json'), isNull);
    expect(
      normalizeDataArchiveEntryName(r'comic_source\source.json'),
      'comic_source/source.json',
    );
  });
}
