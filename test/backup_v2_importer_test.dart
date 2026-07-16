import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/database/backup_v2_importer.dart';
import 'package:venera/utils/backup_v2.dart';

void main() {
  late Directory tempDirectory;
  late Directory dataDirectory;
  late Directory extractedDirectory;
  late Directory localRoot;
  late Directory imageFavoriteAssets;
  late AppDatabase database;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'venera-backup-v2-importer-',
    );
    dataDirectory = Directory(p.join(tempDirectory.path, 'data'))..createSync();
    extractedDirectory = Directory(p.join(tempDirectory.path, 'extracted'))
      ..createSync();
    localRoot = Directory(p.join(tempDirectory.path, 'local'))..createSync();
    imageFavoriteAssets = Directory(
      p.join(tempDirectory.path, 'image-favorite-assets'),
    )..createSync();
    File(
      p.join(imageFavoriteAssets.path, '0123456789abcdef'),
    ).writeAsBytesSync([9, 8, 7]);
    _createLegacyData(dataDirectory, localRoot);
    _writePayload(
      extractedDirectory,
      buildBackupV2Payload(
        dataPath: dataDirectory.path,
        appVersion: '2.0.0-test',
        imageFavoriteAssetsPath: imageFavoriteAssets.path,
      ),
    );
    database = AppDatabase(path: p.join(tempDirectory.path, 'venera.db'));
    await database.initialize();
  });

  tearDown(() async {
    await database.close();
    await tempDirectory.delete(recursive: true);
  });

  test('imports all logical data and records an available archive', () async {
    final importer = BackupV2Importer(
      database,
      clock: () => DateTime.utc(2026, 7, 16),
    );

    final result = await importer.importDirectory(extractedDirectory);

    expect(result.historyCount, 1);
    expect(result.imageFavoriteCount, 1);
    expect(result.imageFavoriteAssetCount, 1);
    expect(result.favoriteCollectionCount, 3);
    expect(result.cookieCount, 1);
    expect(result.downloadTaskCount, 1);
    expect(result.localComicCount, 2);
    expect(result.sourceCount, 1);
    expect(result.availableArchiveCount, 1);
    expect(result.missingArchiveCount, 0);

    final history = await database.raw.get('SELECT * FROM reading_history');
    final historyPayload = jsonDecode(history['payload_json'] as String) as Map;
    expect(history['source_key'], 'source');
    expect(historyPayload['ep'], 3);
    expect(historyPayload['page'], 12);
    expect(historyPayload['chapter_group'], 2);
    expect(historyPayload['readEpisode'], '[1,2,3]');

    final settings = await database.raw.get(
      "SELECT payload_json FROM app_state WHERE section_key = 'settings'",
    );
    expect(jsonDecode(settings['payload_json'] as String), {
      'theme_mode': 'dark',
    });
    final implicitData = await database.raw.get(
      "SELECT payload_json FROM app_state WHERE section_key = 'implicitData'",
    );
    expect(jsonDecode(implicitData['payload_json'] as String), {
      'image_favorites_sort': 'time_desc',
    });

    final imageFavorite = await database.raw.get(
      'SELECT * FROM image_favorites',
    );
    expect(imageFavorite['source_key'], 'source');
    expect(
      jsonDecode(imageFavorite['payload_json'] as String),
      containsPair('id', 'comic-1'),
    );

    final cookie = await database.raw.get('SELECT * FROM cookies');
    expect(cookie['name'], 'session');
    expect(cookie['value'], 'secret');
    expect(cookie['secure'], 0);
    expect(cookie['http_only'], 0);

    final downloadTask = await database.raw.get('SELECT * FROM download_tasks');
    expect(downloadTask['source_key'], 'source');
    expect(downloadTask['comic_id'], 'comic-1');
    expect(downloadTask['state'], 'paused');
    expect(downloadTask['completed_units'], 2);
    expect(downloadTask['total_units'], 10);

    final favorite = await database.raw.get(
      "SELECT payload_json FROM favorite_collections WHERE collection_name = 'Shelf'",
    );
    expect((jsonDecode(favorite['payload_json'] as String) as List).single, {
      'id': 'comic-1',
      'name': 'Favorite',
    });

    final source = await database.raw.get(
      "SELECT * FROM source_documents WHERE name = 'source.json'",
    );
    expect(source['available'], 1);
    expect(utf8.decode(source['content'] as List<int>), '{"key":"source"}');

    final links = await importer.archiveLinks();
    expect(links, hasLength(1));
    expect(links.single.status, ImportedArchiveStatus.available);
    expect(links.single.resolvedPath, endsWith('archive.zip'));

    final payloadCount = await database.raw.get(
      'SELECT COUNT(*) AS count FROM backup_payloads',
    );
    expect(payloadCount['count'], 0);
  });

  test('missing archive survives import and can be safely relinked', () async {
    final importer = BackupV2Importer(database);
    await importer.importDirectory(extractedDirectory);
    final originalMetadata = Directory(
      p.join(localRoot.path, 'comic-dir', '.venera'),
    );
    final relocatedMetadata = Directory(
      p.join(tempDirectory.path, 'relocated', '.venera'),
    )..createSync(recursive: true);
    File(
      p.join(originalMetadata.path, 'archive.zip'),
    ).renameSync(p.join(relocatedMetadata.path, 'archive.zip'));
    File(
      p.join(originalMetadata.path, 'manifest.json'),
    ).renameSync(p.join(relocatedMetadata.path, 'manifest.json'));

    final scanned = await importer.scanArchiveAvailability();
    expect(scanned.single.status, ImportedArchiveStatus.missing);
    expect(scanned.single.resolvedPath, isNull);

    final relinked = await importer.relinkArchive(
      comicId: 'local-1',
      comicType: 42,
      archivePath: p.join(relocatedMetadata.path, 'archive.zip'),
    );
    expect(relinked.status, ImportedArchiveStatus.relinked);

    // Importing the same snapshot again keeps a still-valid manual link.
    await importer.importDirectory(extractedDirectory);
    final afterReimport = (await importer.archiveLinks()).single;
    expect(afterReimport.status, ImportedArchiveStatus.relinked);
    expect(afterReimport.resolvedPath, relinked.resolvedPath);
  });

  test(
    'recompressed archive reconnects when its identity still matches',
    () async {
      final archive = File(
        p.join(localRoot.path, 'comic-dir', '.venera', 'archive.zip'),
      );
      archive.writeAsBytesSync([9, 9, 9], mode: FileMode.append, flush: true);

      final result = await BackupV2Importer(
        database,
      ).importDirectory(extractedDirectory);
      final link = (await BackupV2Importer(database).archiveLinks()).single;

      expect(result.availableArchiveCount, 1);
      expect(link.status, ImportedArchiveStatus.available);
      expect(link.resolvedPath, archive.path);
    },
  );

  test(
    'malformed projection does not partially replace imported data',
    () async {
      final importer = BackupV2Importer(database);
      await importer.importDirectory(extractedDirectory);
      final historyPath = p.join(
        extractedDirectory.path,
        backupLogicalDirectory,
        'history.json',
      );
      final malformed = utf8.encode('{}');
      File(historyPath).writeAsBytesSync(malformed);
      final oldManifest = validateExtractedBackupV2(
        _restoreManifestForPayloadRewrite(extractedDirectory, malformed),
      )!;
      expect(oldManifest.entries, isNotEmpty);

      await expectLater(
        importer.importDirectory(extractedDirectory),
        throwsA(isA<FormatException>()),
      );

      final history = await database.raw.get('SELECT * FROM reading_history');
      final payload = jsonDecode(history['payload_json'] as String) as Map;
      expect(payload['page'], 12);
    },
  );

  test('early V2 history without source_key keeps its progress', () async {
    final historyPath = p.join(
      extractedDirectory.path,
      backupLogicalDirectory,
      'history.json',
    );
    final rows = jsonDecode(File(historyPath).readAsStringSync()) as List;
    final row = Map<String, dynamic>.from(rows.single as Map)
      ..remove('source_key')
      ..['type'] = 42;
    final rewritten = utf8.encode(jsonEncode([row]));
    File(historyPath).writeAsBytesSync(rewritten);
    _restoreManifestForPayloadRewrite(extractedDirectory, rewritten);

    await BackupV2Importer(database).importDirectory(extractedDirectory);

    final imported = await database.raw.get('SELECT * FROM reading_history');
    expect(imported['source_key'], 'Unknown:42');
    expect(
      jsonDecode(imported['payload_json'] as String),
      containsPair('page', 12),
    );
  });

  test(
    'early V2 keeps rewrite data for sections it does not contain',
    () async {
      final importer = BackupV2Importer(database);
      await importer.importDirectory(extractedDirectory);
      await database.raw.writeTransaction((tx) async {
        await tx.execute(
          "UPDATE app_state SET payload_json = '{\"kept\":true}' "
          "WHERE section_key = 'implicitData'",
        );
        await tx.execute(
          "UPDATE image_favorites SET payload_json = '{\"kept\":true}'",
        );
        await tx.execute("UPDATE cookies SET value = 'kept-cookie'");
        await tx.execute("UPDATE download_tasks SET state = 'failed'");
      });

      _removeLogicalSections(extractedDirectory, {
        'implicit_data.json',
        'image_favorites.json',
        'image_favorite_assets.json',
        'cookies.json',
        'download_tasks.json',
      });

      await importer.importDirectory(extractedDirectory);

      final implicit = await database.raw.get(
        "SELECT payload_json FROM app_state WHERE section_key = 'implicitData'",
      );
      final imageFavorite = await database.raw.get(
        'SELECT payload_json FROM image_favorites',
      );
      final cookie = await database.raw.get('SELECT value FROM cookies');
      final downloadTask = await database.raw.get(
        'SELECT state FROM download_tasks',
      );
      expect(jsonDecode(implicit['payload_json'] as String), {'kept': true});
      expect(jsonDecode(imageFavorite['payload_json'] as String), {
        'kept': true,
      });
      expect(cookie['value'], 'kept-cookie');
      expect(downloadTask['state'], 'failed');
    },
  );
}

void _createLegacyData(Directory dataDirectory, Directory localRoot) {
  File(p.join(dataDirectory.path, 'appdata.json')).writeAsStringSync(
    jsonEncode({
      'settings': {'theme_mode': 'dark'},
      'searchHistory': ['query'],
    }),
  );
  File(
    p.join(dataDirectory.path, 'implicitData.json'),
  ).writeAsStringSync(jsonEncode({'image_favorites_sort': 'time_desc'}));
  File(
    p.join(dataDirectory.path, 'local_path'),
  ).writeAsStringSync(localRoot.path);

  final history = sqlite3.open(p.join(dataDirectory.path, 'history.db'));
  history.execute('''
    CREATE TABLE history(
      id TEXT, source_key TEXT, ep INTEGER, page INTEGER,
      chapter_group INTEGER, readEpisode TEXT
    );
  ''');
  history.execute('INSERT INTO history VALUES (?, ?, ?, ?, ?, ?)', [
    'comic-1',
    'source',
    3,
    12,
    2,
    '[1,2,3]',
  ]);
  history.execute('''
    CREATE TABLE image_favorites(
      id TEXT, title TEXT, source_key TEXT, image_favorites_ep TEXT
    );
  ''');
  history.execute('INSERT INTO image_favorites VALUES (?, ?, ?, ?)', [
    'comic-1',
    'Favorite image comic',
    'source',
    '[{"ep":3,"imageFavorites":[{"page":12}]}]',
  ]);
  history.close();

  final cookies = sqlite3.open(p.join(dataDirectory.path, 'cookie.db'));
  cookies.execute('''
    CREATE TABLE cookies(
      name TEXT, value TEXT, domain TEXT, path TEXT, expires INTEGER,
      secure INTEGER, httpOnly INTEGER
    );
  ''');
  cookies.execute('INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?)', [
    'session',
    'secret',
    'example.test',
    '/',
    null,
    null,
    null,
  ]);
  cookies.close();

  File(p.join(dataDirectory.path, 'downloading_tasks.json')).writeAsStringSync(
    jsonEncode([
      {
        'type': 'ImagesDownloadTask',
        'source': 'source',
        'comicId': 'comic-1',
        'downloadedCount': 2,
        'totalCount': 10,
      },
    ]),
  );

  final favorites = sqlite3.open(
    p.join(dataDirectory.path, 'local_favorite.db'),
  );
  favorites.execute(
    'CREATE TABLE folder_order(folder_name TEXT, order_value INTEGER)',
  );
  favorites.execute(
    'CREATE TABLE folder_sync(folder_name TEXT, source_key TEXT)',
  );
  favorites.execute('CREATE TABLE Shelf(id TEXT, name TEXT)');
  favorites.execute("INSERT INTO Shelf VALUES ('comic-1', 'Favorite')");
  favorites.close();

  final local = sqlite3.open(p.join(dataDirectory.path, 'local.db'));
  local.execute('''
    CREATE TABLE comics(
      id TEXT, comic_type INTEGER, directory TEXT, title TEXT
    )
  ''');
  local.execute('INSERT INTO comics VALUES (?, ?, ?, ?)', [
    'local-1',
    42,
    'comic-dir',
    'Local comic',
  ]);
  local.execute('INSERT INTO comics VALUES (?, ?, ?, ?)', [
    'local-2',
    42,
    'loose-comic-dir',
    'Uncompressed local comic',
  ]);
  local.close();

  final sourceDirectory = Directory(p.join(dataDirectory.path, 'comic_source'))
    ..createSync();
  File(
    p.join(sourceDirectory.path, 'source.json'),
  ).writeAsStringSync('{"key":"source"}');

  final metadata = Directory(p.join(localRoot.path, 'comic-dir', '.venera'))
    ..createSync(recursive: true);
  File(p.join(metadata.path, 'archive.zip')).writeAsBytesSync([1, 2, 3, 4]);
  File(p.join(metadata.path, 'manifest.json')).writeAsStringSync(
    jsonEncode({
      'version': 1,
      'comic': {'id': 'local-1', 'sourceKey': 'source', 'comicType': 42},
      'createdAt': 1,
      'entries': [
        {
          'path': '1.jpg',
          'size': 1,
          'modifiedAt': 1,
          'sha256': List.filled(64, '0').join(),
        },
      ],
    }),
  );
}

void _writePayload(Directory directory, BackupV2Payload payload) {
  for (final entry in payload.entries.entries) {
    final file = File(p.joinAll([directory.path, ...entry.key.split('/')]))
      ..createSync(recursive: true)
      ..writeAsBytesSync(entry.value);
    expect(file.existsSync(), isTrue);
  }
  File(
    p.join(directory.path, backupManifestEntryName),
  ).writeAsStringSync(jsonEncode(payload.manifest.toJson()));
}

Directory _restoreManifestForPayloadRewrite(
  Directory directory,
  List<int> historyBytes,
) {
  final manifestFile = File(p.join(directory.path, backupManifestEntryName));
  final decoded = jsonDecode(manifestFile.readAsStringSync()) as Map;
  final entries = decoded['entries'] as List;
  for (final raw in entries) {
    final entry = raw as Map;
    if (entry['path'] == '$backupLogicalDirectory/history.json') {
      entry['length'] = historyBytes.length;
      entry['sha256'] = sha256.convert(historyBytes).toString();
    }
  }
  manifestFile.writeAsStringSync(jsonEncode(decoded));
  return directory;
}

void _removeLogicalSections(Directory directory, Set<String> names) {
  final manifestFile = File(p.join(directory.path, backupManifestEntryName));
  final manifest = BackupManifestV2.tryParse(
    jsonDecode(manifestFile.readAsStringSync()),
  )!;
  final removedPaths = manifest.entries
      .where(
        (entry) =>
            names.contains(p.posix.basename(entry.path)) ||
            (names.contains('image_favorite_assets.json') &&
                entry.path.startsWith(
                  '$backupLogicalDirectory/image_favorite_assets/',
                )),
      )
      .map((entry) => entry.path)
      .toSet();
  for (final path in removedPaths) {
    File(p.joinAll([directory.path, ...path.split('/')])).deleteSync();
  }
  final updated = BackupManifestV2(
    createdAt: manifest.createdAt,
    appVersion: manifest.appVersion,
    isFullBackup: manifest.isFullBackup,
    entries: manifest.entries
        .where((entry) => !removedPaths.contains(entry.path))
        .toList(growable: false),
  );
  manifestFile.writeAsStringSync(jsonEncode(updated.toJson()));
}
