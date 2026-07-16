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
  late AppDatabase database;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'venera-backup-v2-importer-',
    );
    dataDirectory = Directory(p.join(tempDirectory.path, 'data'))..createSync();
    extractedDirectory = Directory(p.join(tempDirectory.path, 'extracted'))
      ..createSync();
    localRoot = Directory(p.join(tempDirectory.path, 'local'))..createSync();
    _createLegacyData(dataDirectory, localRoot);
    _writePayload(
      extractedDirectory,
      buildBackupV2Payload(
        dataPath: dataDirectory.path,
        appVersion: '2.0.0-test',
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
    expect(result.favoriteCollectionCount, 3);
    expect(result.localComicCount, 1);
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
    final manifest = validateExtractedBackupV2(extractedDirectory)!;
    expect(payloadCount['count'], manifest.entries.length);
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
}

void _createLegacyData(Directory dataDirectory, Directory localRoot) {
  File(p.join(dataDirectory.path, 'appdata.json')).writeAsStringSync(
    jsonEncode({
      'settings': {'theme_mode': 'dark'},
      'searchHistory': ['query'],
    }),
  );
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
  history.close();

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
