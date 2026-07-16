import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/core/database/backup_import_coordinator.dart';

void main() {
  late Directory root;
  late Directory source;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-import-target-');
    source = await Directory.systemTemp.createTemp('venera-import-source-');
  });

  tearDown(() async {
    await root.delete(recursive: true);
    await source.delete(recursive: true);
  });

  test('commit replaces files and directories as one prepared batch', () async {
    File(p.join(root.path, 'history.db')).writeAsStringSync('old-history');
    final oldSources = Directory(p.join(root.path, 'comic_source'))
      ..createSync();
    File(p.join(oldSources.path, 'old.json')).writeAsStringSync('old-source');

    final history = File(p.join(source.path, 'history.db'))
      ..writeAsStringSync('new-history');
    final sources = Directory(p.join(source.path, 'comic_source'))
      ..createSync();
    File(p.join(sources.path, 'new.json')).writeAsStringSync('new-source');

    final coordinator = BackupImportCoordinator(root, operationId: 'commit');
    final prepared = await coordinator.prepare([
      BackupImportSource(relativePath: 'history.db', source: history),
      BackupImportSource(relativePath: 'comic_source', source: sources),
    ]);

    await coordinator.commit(prepared);

    expect(
      File(p.join(root.path, 'history.db')).readAsStringSync(),
      'new-history',
    );
    expect(
      File(p.join(root.path, 'comic_source', 'new.json')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(root.path, 'comic_source', 'old.json')).existsSync(),
      isFalse,
    );
    _expectNoTransactionArtifacts(root);
  });

  test(
    'commit failure restores every original and removes new targets',
    () async {
      File(p.join(root.path, 'history.db')).writeAsStringSync('old-history');
      final history = File(p.join(source.path, 'history.db'))
        ..writeAsStringSync('new-history');
      final rewrite = File(p.join(source.path, 'venera.db'))
        ..writeAsStringSync('new-rewrite');
      final coordinator = BackupImportCoordinator(
        root,
        operationId: 'failure',
        afterStep: (step) async {
          if (step == 'installed:venera.db') {
            throw StateError('injected commit failure');
          }
        },
      );
      final prepared = await coordinator.prepare([
        BackupImportSource(relativePath: 'history.db', source: history),
        BackupImportSource(relativePath: 'venera.db', source: rewrite),
      ]);

      await expectLater(
        coordinator.commit(prepared),
        throwsA(isA<StateError>()),
      );

      expect(
        File(p.join(root.path, 'history.db')).readAsStringSync(),
        'old-history',
      );
      expect(File(p.join(root.path, 'venera.db')).existsSync(), isFalse);
      _expectNoTransactionArtifacts(root);
    },
  );

  test(
    'startup recovery rolls back a process interrupted after rename',
    () async {
      final target = File(p.join(root.path, 'history.db'))
        ..writeAsStringSync('old-history');
      final imported = File(p.join(source.path, 'history.db'))
        ..writeAsStringSync('new-history');
      final coordinator = BackupImportCoordinator(root, operationId: 'crash');
      await coordinator.prepare([
        BackupImportSource(relativePath: 'history.db', source: imported),
      ]);

      final backup = File(
        p.join(root.path, '.venera-backup-import.bak', 'history.db'),
      )..parent.createSync(recursive: true);
      target.renameSync(backup.path);
      File(
        p.join(root.path, '.venera-backup-import.incoming', 'history.db'),
      ).renameSync(target.path);

      await BackupImportCoordinator(root).recoverInterruptedImport();

      expect(target.readAsStringSync(), 'old-history');
      _expectNoTransactionArtifacts(root);
    },
  );

  test('verification failure rolls back installed data', () async {
    final target = File(p.join(root.path, 'history.db'))
      ..writeAsStringSync('old-history');
    final imported = File(p.join(source.path, 'history.db'))
      ..writeAsStringSync('new-history');
    final coordinator = BackupImportCoordinator(root, operationId: 'verify');
    final prepared = await coordinator.prepare([
      BackupImportSource(relativePath: 'history.db', source: imported),
    ]);

    await expectLater(
      coordinator.commit(
        prepared,
        verify: () async => throw const FormatException('invalid database'),
      ),
      throwsA(isA<FormatException>()),
    );

    expect(target.readAsStringSync(), 'old-history');
    _expectNoTransactionArtifacts(root);
  });

  test('prepare rejects traversal and overlapping targets', () async {
    final file = File(p.join(source.path, 'data'))..writeAsStringSync('data');
    final directory = Directory(p.join(source.path, 'directory'))..createSync();

    await expectLater(
      BackupImportCoordinator(root).prepare([
        BackupImportSource(relativePath: '../history.db', source: file),
      ]),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      BackupImportCoordinator(root).prepare([
        BackupImportSource(relativePath: 'comic_source', source: directory),
        BackupImportSource(relativePath: 'comic_source/a.json', source: file),
      ]),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      BackupImportCoordinator(root).prepare([
        BackupImportSource(relativePath: 'History.db', source: file),
        BackupImportSource(relativePath: 'history.db', source: file),
      ]),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      BackupImportCoordinator(root).prepare([
        BackupImportSource(
          relativePath: '.VENERA-BACKUP-IMPORT.BAK/data',
          source: file,
        ),
      ]),
      throwsA(isA<FormatException>()),
    );
  });
}

void _expectNoTransactionArtifacts(Directory root) {
  expect(
    File(p.join(root.path, '.venera-backup-import.json')).existsSync(),
    isFalse,
  );
  expect(
    Directory(p.join(root.path, '.venera-backup-import.incoming')).existsSync(),
    isFalse,
  );
  expect(
    Directory(p.join(root.path, '.venera-backup-import.bak')).existsSync(),
    isFalse,
  );
}
