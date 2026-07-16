import 'dart:convert';
import 'dart:io';

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
    history.close();

    final payload = buildBackupV2Payload(
      dataPath: tempDir.path,
      appVersion: 'test',
    );

    expect(payload.manifest.appVersion, 'test');
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

  test('archive entry normalization rejects traversal and absolute paths', () {
    expect(normalizeDataArchiveEntryName('../history.db'), isNull);
    expect(normalizeDataArchiveEntryName(r'C:\history.db'), isNull);
    expect(normalizeDataArchiveEntryName('/history.db'), isNull);
    expect(
      normalizeDataArchiveEntryName(r'comic_source\source.json'),
      'comic_source/source.json',
    );
  });
}
