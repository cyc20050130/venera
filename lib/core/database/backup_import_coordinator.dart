import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A source entity that will replace [relativePath] below the application data
/// directory as part of one backup import transaction.
final class BackupImportSource {
  const BackupImportSource({required this.relativePath, required this.source});

  final String relativePath;
  final FileSystemEntity source;
}

/// An immutable handle returned after all imported entities have been copied
/// next to their final destinations.
final class PreparedBackupImport {
  const PreparedBackupImport._({
    required this.operationId,
    required this.relativePaths,
  });

  final String operationId;
  final List<String> relativePaths;
}

/// Atomically installs the file-based part of an application backup.
///
/// Imported files are first copied into the application data directory so the
/// final commit only uses same-volume renames. A durable journal and retained
/// originals allow [recoverInterruptedImport] to roll back a process that was
/// interrupted at any point before the commit marker was written.
final class BackupImportCoordinator {
  BackupImportCoordinator(
    this.dataDirectory, {
    String? operationId,
    Future<void> Function(String step)? afterStep,
  }) : operationId =
           operationId ??
           DateTime.now().microsecondsSinceEpoch.toRadixString(36),
       _afterStep = afterStep;

  final Directory dataDirectory;
  final String operationId;
  final Future<void> Function(String step)? _afterStep;

  static const _journalName = '.venera-backup-import.json';
  static const _incomingName = '.venera-backup-import.incoming';
  static const _backupName = '.venera-backup-import.bak';

  File get _journal => File(p.join(dataDirectory.path, _journalName));
  File get _journalTemp => File('${_journal.path}.tmp');
  File get _journalPrevious => File('${_journal.path}.previous');
  Directory get _incoming =>
      Directory(p.join(dataDirectory.path, _incomingName));
  Directory get _backup => Directory(p.join(dataDirectory.path, _backupName));

  Future<PreparedBackupImport> prepare(
    Iterable<BackupImportSource> sources,
  ) async {
    await dataDirectory.create(recursive: true);
    await recoverInterruptedImport();

    final normalized = <({String path, FileSystemEntity source})>[];
    final seen = <String>{};
    for (final source in sources) {
      final relativePath = _normalizeRelativePath(source.relativePath);
      // Backups move between Windows, Apple, Android, and Linux filesystems.
      // Reject case-only duplicates everywhere so an archive prepared on a
      // case-sensitive host cannot overwrite itself when imported elsewhere.
      final key = relativePath.toLowerCase();
      if (!seen.add(key)) {
        throw FormatException('Duplicate backup import path: $relativePath');
      }
      final sourceType = await FileSystemEntity.type(
        source.source.path,
        followLinks: false,
      );
      if (sourceType != FileSystemEntityType.file &&
          sourceType != FileSystemEntityType.directory) {
        throw FormatException('Backup import source is missing: $relativePath');
      }
      normalized.add((path: relativePath, source: source.source));
    }
    _rejectOverlappingPaths(normalized.map((entry) => entry.path));
    if (normalized.isEmpty) {
      throw const FormatException('Backup import contains no installable data');
    }

    await _incoming.deleteIfExists(recursive: true);
    await _backup.deleteIfExists(recursive: true);
    await _incoming.create(recursive: true);

    try {
      final entries = <_JournalEntry>[];
      for (final entry in normalized) {
        final stagedPath = _resolve(_incoming, entry.path);
        await _copyEntity(entry.source, stagedPath);
        entries.add(
          _JournalEntry(
            relativePath: entry.path,
            originallyExisted:
                await FileSystemEntity.type(
                  _resolve(dataDirectory, entry.path),
                  followLinks: false,
                ) !=
                FileSystemEntityType.notFound,
          ),
        );
      }
      await _writeJournal(
        _ImportJournal(
          operationId: operationId,
          phase: _ImportPhase.prepared,
          sequence: 1,
          entries: entries,
        ),
      );
      await _notify('prepared');
      return PreparedBackupImport._(
        operationId: operationId,
        relativePaths: List.unmodifiable(
          entries.map((entry) => entry.relativePath),
        ),
      );
    } catch (_) {
      await _cleanupTransactionFiles();
      rethrow;
    }
  }

  /// Installs all staged entities, retaining originals until [verify] succeeds.
  Future<void> commit(
    PreparedBackupImport prepared, {
    Future<void> Function()? verify,
  }) async {
    var journal = await _requireJournal(prepared);
    if (journal.phase != _ImportPhase.prepared) {
      throw StateError('Backup import is not prepared');
    }
    journal = journal.next(_ImportPhase.committing);
    await _writeJournal(journal);
    try {
      await _backup.create(recursive: true);
      for (final entry in journal.entries) {
        final targetPath = _resolve(dataDirectory, entry.relativePath);
        final backupPath = _resolve(_backup, entry.relativePath);
        final stagedPath = _resolve(_incoming, entry.relativePath);
        final targetType = await FileSystemEntity.type(
          targetPath,
          followLinks: false,
        );
        if (targetType != FileSystemEntityType.notFound) {
          await Directory(p.dirname(backupPath)).create(recursive: true);
          await _renameEntity(targetPath, backupPath);
        }
        await _notify('backed-up:${entry.relativePath}');
        await Directory(p.dirname(targetPath)).create(recursive: true);
        await _renameEntity(stagedPath, targetPath);
        await _notify('installed:${entry.relativePath}');
      }
      journal = journal.next(_ImportPhase.installed);
      await _writeJournal(journal);
      await verify?.call();
      journal = journal.next(_ImportPhase.committed);
      await _writeJournal(journal);
      await _notify('committed');
      await _cleanupTransactionFiles();
    } catch (error, stackTrace) {
      await _rollbackJournal(journal);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> rollback([PreparedBackupImport? prepared]) async {
    final journal = await _readLatestJournal();
    if (journal == null) {
      await _cleanupTransactionFiles();
      return;
    }
    if (prepared != null && prepared.operationId != journal.operationId) {
      throw StateError('Prepared backup import does not match the journal');
    }
    await _rollbackJournal(journal);
  }

  /// Completes cleanup for a committed import, or restores the previous data
  /// for every earlier phase.
  Future<void> recoverInterruptedImport() async {
    final journal = await _readLatestJournal();
    if (journal == null) {
      if (await _backup.exists()) {
        throw const FormatException(
          'Backup import artifacts exist without a valid transaction journal',
        );
      }
      // A process can stop while prepare is still copying, before any target
      // has been touched or the first journal has been published.
      await _incoming.deleteIfExists(recursive: true);
      await _deleteJournalCandidates();
      return;
    }
    if (journal.phase == _ImportPhase.committed) {
      await _cleanupTransactionFiles();
      return;
    }
    await _rollbackJournal(journal);
  }

  Future<_ImportJournal> _requireJournal(PreparedBackupImport prepared) async {
    final journal = await _readLatestJournal();
    if (journal == null || journal.operationId != prepared.operationId) {
      throw StateError('Prepared backup import does not match the journal');
    }
    return journal;
  }

  Future<void> _rollbackJournal(_ImportJournal journal) async {
    for (final entry in journal.entries.reversed) {
      final targetPath = _resolve(dataDirectory, entry.relativePath);
      final backupPath = _resolve(_backup, entry.relativePath);
      final stagedPath = _resolve(_incoming, entry.relativePath);
      final backupExists =
          await FileSystemEntity.type(backupPath, followLinks: false) !=
          FileSystemEntityType.notFound;
      if (backupExists) {
        await _deleteEntityIfExists(targetPath);
        await Directory(p.dirname(targetPath)).create(recursive: true);
        await _renameEntity(backupPath, targetPath);
      } else if (!entry.originallyExisted) {
        final stagedExists =
            await FileSystemEntity.type(stagedPath, followLinks: false) !=
            FileSystemEntityType.notFound;
        if (!stagedExists) {
          await _deleteEntityIfExists(targetPath);
        }
      }
    }
    await _notify('rolled-back');
    await _cleanupTransactionFiles();
  }

  Future<void> _writeJournal(_ImportJournal journal) async {
    await _journalTemp.writeAsString(jsonEncode(journal.toJson()), flush: true);
    await _journalPrevious.deleteIfExists();
    if (await _journal.exists()) {
      await _journal.rename(_journalPrevious.path);
    }
    await _journalTemp.rename(_journal.path);
  }

  Future<_ImportJournal?> _readLatestJournal() async {
    final candidates = <_ImportJournal>[];
    for (final file in [_journal, _journalTemp, _journalPrevious]) {
      if (!await file.exists()) continue;
      try {
        final decoded = jsonDecode(await file.readAsString());
        final journal = _ImportJournal.tryParse(decoded);
        if (journal != null) candidates.add(journal);
      } catch (_) {
        // Another durable candidate may still contain the last valid state.
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.sequence.compareTo(a.sequence));
    return candidates.first;
  }

  Future<void> _cleanupTransactionFiles() async {
    await _incoming.deleteIfExists(recursive: true);
    await _backup.deleteIfExists(recursive: true);
    await _deleteJournalCandidates();
  }

  Future<void> _deleteJournalCandidates() async {
    await _journal.deleteIfExists();
    await _journalTemp.deleteIfExists();
    await _journalPrevious.deleteIfExists();
  }

  Future<void> _notify(String step) async {
    await _afterStep?.call(step);
  }
}

enum _ImportPhase { prepared, committing, installed, committed }

final class _JournalEntry {
  const _JournalEntry({
    required this.relativePath,
    required this.originallyExisted,
  });

  final String relativePath;
  final bool originallyExisted;

  Map<String, Object?> toJson() => {
    'relativePath': relativePath,
    'originallyExisted': originallyExisted,
  };

  static _JournalEntry? tryParse(Object? value) {
    if (value is! Map ||
        value['relativePath'] is! String ||
        value['originallyExisted'] is! bool) {
      return null;
    }
    try {
      return _JournalEntry(
        relativePath: _normalizeRelativePath(value['relativePath'] as String),
        originallyExisted: value['originallyExisted'] as bool,
      );
    } catch (_) {
      return null;
    }
  }
}

final class _ImportJournal {
  const _ImportJournal({
    required this.operationId,
    required this.phase,
    required this.sequence,
    required this.entries,
  });

  final String operationId;
  final _ImportPhase phase;
  final int sequence;
  final List<_JournalEntry> entries;

  _ImportJournal next(_ImportPhase nextPhase) => _ImportJournal(
    operationId: operationId,
    phase: nextPhase,
    sequence: sequence + 1,
    entries: entries,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'operationId': operationId,
    'phase': phase.name,
    'sequence': sequence,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };

  static _ImportJournal? tryParse(Object? value) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['operationId'] is! String ||
        value['sequence'] is! int ||
        value['entries'] is! List) {
      return null;
    }
    final operationId = value['operationId'] as String;
    final sequence = value['sequence'] as int;
    final phase = _ImportPhase.values
        .where((candidate) => candidate.name == value['phase'])
        .firstOrNull;
    final entries = (value['entries'] as List)
        .map(_JournalEntry.tryParse)
        .toList();
    if (operationId.isEmpty ||
        sequence < 1 ||
        phase == null ||
        entries.isEmpty ||
        entries.any((entry) => entry == null)) {
      return null;
    }
    final parsedEntries = entries.cast<_JournalEntry>();
    try {
      _rejectOverlappingPaths(parsedEntries.map((entry) => entry.relativePath));
    } catch (_) {
      return null;
    }
    return _ImportJournal(
      operationId: operationId,
      phase: phase,
      sequence: sequence,
      entries: parsedEntries,
    );
  }
}

String _normalizeRelativePath(String value) {
  final normalized = value.replaceAll('\\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    throw FormatException('Unsafe backup import path: $value');
  }
  final segments = normalized.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw FormatException('Unsafe backup import path: $value');
  }
  if (segments.first.toLowerCase().startsWith('.venera-backup-import')) {
    throw FormatException('Reserved backup import path: $value');
  }
  return segments.join('/');
}

void _rejectOverlappingPaths(Iterable<String> paths) {
  final normalized = paths.map((path) => path.toLowerCase()).toList()..sort();
  for (var index = 1; index < normalized.length; index++) {
    if (normalized[index].startsWith('${normalized[index - 1]}/')) {
      throw FormatException(
        'Overlapping backup import paths: ${normalized[index - 1]}',
      );
    }
  }
}

String _resolve(Directory root, String relativePath) =>
    p.joinAll([root.path, ...relativePath.split('/')]);

Future<void> _copyEntity(FileSystemEntity source, String destination) async {
  final type = await FileSystemEntity.type(source.path, followLinks: false);
  if (type == FileSystemEntityType.file) {
    await Directory(p.dirname(destination)).create(recursive: true);
    await File(source.path).copy(destination);
    return;
  }
  if (type != FileSystemEntityType.directory) {
    throw FormatException('Unsupported backup import entity: ${source.path}');
  }
  final destinationDirectory = Directory(destination);
  await destinationDirectory.create(recursive: true);
  await for (final child in Directory(source.path).list(followLinks: false)) {
    await _copyEntity(child, p.join(destination, p.basename(child.path)));
  }
}

Future<void> _deleteEntityIfExists(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  } else {
    await File(path).delete();
  }
}

Future<void> _renameEntity(String source, String destination) async {
  final type = await FileSystemEntity.type(source, followLinks: false);
  if (type == FileSystemEntityType.directory) {
    await Directory(source).rename(destination);
  } else if (type == FileSystemEntityType.file) {
    await File(source).rename(destination);
  } else {
    throw FileSystemException('Import entity is missing', source);
  }
}

extension on FileSystemEntity {
  Future<void> deleteIfExists({bool recursive = false}) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    await delete(recursive: recursive);
  }
}
