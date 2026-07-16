import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/utils/backup_v2.dart' show requiredRewriteBackupPaths;

/// Durable state of the one-time rewrite upgrade.
enum RewriteUpgradePhase {
  notRequired,
  backupRequired,
  backupVerified,
  resetting,
  resetCompleted,
}

final class RewriteUpgradeSnapshot {
  const RewriteUpgradeSnapshot({
    required this.phase,
    required this.preservedLocalRoots,
    this.savedBackupPath,
    this.backupAppVersion,
    this.backupCreatedAt,
    this.backupFingerprint,
  });

  final RewriteUpgradePhase phase;
  final List<String> preservedLocalRoots;
  final String? savedBackupPath;
  final String? backupAppVersion;
  final DateTime? backupCreatedAt;
  final String? backupFingerprint;

  bool get blocksStartup => phase != RewriteUpgradePhase.notRequired;
}

/// Coordinates the destructive V2 rewrite without ever deleting comic files.
///
/// The journal deliberately lives beside the legacy data. A reset is announced
/// durably before the first file is removed, so a process crash can only cause
/// the idempotent reset to continue on the next launch. The managed `local`
/// directory and the directory referenced by `local_path` are never reset.
final class RewriteUpgradeCoordinator {
  RewriteUpgradeCoordinator({
    required this.dataDirectory,
    required this.cacheDirectory,
    this.targetVersion = currentTargetVersion,
    Iterable<String> additionalPreservedLocalRoots = const [],
    DateTime Function()? clock,
    Future<void> Function(String step)? afterStep,
  }) : _clock = clock ?? DateTime.now,
       _afterStep = afterStep,
       _additionalPreservedLocalRoots = additionalPreservedLocalRoots
           .where((path) => path.trim().isNotEmpty)
           .map(_normalizeAbsolute)
           .toSet();

  static const int currentTargetVersion = 2;
  static const String markerFileName = '.venera-rewrite-v2.json';
  static const String journalFileName = '.venera-rewrite-upgrade.json';
  static const Set<String> requiredBackupEntryPaths =
      requiredRewriteBackupPaths;

  final Directory dataDirectory;
  final Directory cacheDirectory;
  final int targetVersion;
  final DateTime Function() _clock;
  final Future<void> Function(String step)? _afterStep;
  final Set<String> _additionalPreservedLocalRoots;

  File get _marker => File(p.join(dataDirectory.path, markerFileName));
  File get _journal => File(p.join(dataDirectory.path, journalFileName));
  File get _journalTemp => File('${_journal.path}.tmp');
  File get _journalPrevious => File('${_journal.path}.previous');

  /// Inspects the installation and finishes an already-confirmed interrupted
  /// reset. It never starts a destructive reset merely because legacy data was
  /// found.
  Future<RewriteUpgradeSnapshot> inspectAndRecover() async {
    await dataDirectory.create(recursive: true);
    final journal = await _readLatestJournal();
    if (journal != null) {
      if (journal.targetVersion != targetVersion) {
        throw const FormatException('Unsupported rewrite upgrade journal');
      }
      if (journal.phase == RewriteUpgradePhase.resetting) {
        await _performReset(journal.preservedLocalRoots);
        await _writeCompletionMarker();
        final completed = journal.next(RewriteUpgradePhase.resetCompleted);
        await _writeJournal(completed);
        await _notify('reset-recovered');
        return completed.toSnapshot();
      }
      if (journal.phase == RewriteUpgradePhase.resetCompleted) {
        await _writeCompletionMarker();
      }
      return journal.toSnapshot();
    }

    if (await _hasInvalidJournalArtifacts()) {
      throw const FormatException(
        'Rewrite upgrade artifacts exist without a valid journal',
      );
    }

    if (await _hasCurrentMarker()) {
      return RewriteUpgradeSnapshot(
        phase: RewriteUpgradePhase.notRequired,
        preservedLocalRoots: await _discoverPreservedLocalRoots(),
      );
    }

    final preservedRoots = await _discoverPreservedLocalRoots();
    if (await _containsLegacyData()) {
      return RewriteUpgradeSnapshot(
        phase: RewriteUpgradePhase.backupRequired,
        preservedLocalRoots: preservedRoots,
      );
    }

    await _writeCompletionMarker();
    return RewriteUpgradeSnapshot(
      phase: RewriteUpgradePhase.notRequired,
      preservedLocalRoots: preservedRoots,
    );
  }

  /// Records a validated V2 backup only after the platform save dialog reports
  /// a destination outside application-owned data and cache directories.
  Future<RewriteUpgradeSnapshot> recordVerifiedBackup({
    required String savedBackupPath,
    required String backupAppVersion,
    required DateTime backupCreatedAt,
    required String backupFingerprint,
    required Iterable<String> verifiedEntryPaths,
  }) async {
    final normalizedPath = _validateExternalBackupPath(savedBackupPath);
    if (backupAppVersion.trim().isEmpty) {
      throw const FormatException('Backup app version is missing');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(backupFingerprint)) {
      throw const FormatException('Backup fingerprint is invalid');
    }
    final verifiedEntries = verifiedEntryPaths.toSet();
    final missingEntries = requiredBackupEntryPaths.difference(verifiedEntries);
    if (missingEntries.isNotEmpty) {
      throw FormatException(
        'Backup is incomplete; missing: ${missingEntries.toList()..sort()}',
      );
    }
    final journal = _RewriteUpgradeJournal(
      targetVersion: targetVersion,
      phase: RewriteUpgradePhase.backupVerified,
      sequence: 1,
      savedBackupPath: normalizedPath,
      backupAppVersion: backupAppVersion,
      backupCreatedAt: backupCreatedAt.toUtc(),
      backupFingerprint: backupFingerprint,
      verifiedEntryPaths: verifiedEntries.toList(growable: false)..sort(),
      preservedLocalRoots: await _discoverPreservedLocalRoots(),
    );
    await _writeJournal(journal);
    await _notify('backup-verified');
    return journal.toSnapshot();
  }

  /// Performs the user-confirmed reset. Callers must present their own second
  /// confirmation UI and pass [confirmed] only for an affirmative result.
  Future<RewriteUpgradeSnapshot> resetAfterConfirmation({
    required bool confirmed,
  }) async {
    if (!confirmed) {
      throw StateError('Rewrite reset was not confirmed');
    }
    final current = await _readLatestJournal();
    if (current == null ||
        current.targetVersion != targetVersion ||
        current.phase != RewriteUpgradePhase.backupVerified) {
      throw StateError('A verified external V2 backup is required');
    }

    final resetting = current.next(RewriteUpgradePhase.resetting);
    await _writeJournal(resetting);
    await _notify('reset-started');
    await _performReset(resetting.preservedLocalRoots);
    await _writeCompletionMarker();
    final completed = resetting.next(RewriteUpgradePhase.resetCompleted);
    await _writeJournal(completed);
    await _notify('reset-completed');
    return completed.toSnapshot();
  }

  /// Removes the completed journal after the user has acknowledged the final
  /// screen. The rewrite marker remains the permanent startup gate bypass.
  Future<void> acknowledgeCompletion() async {
    final journal = await _readLatestJournal();
    if (journal != null &&
        journal.phase != RewriteUpgradePhase.resetCompleted) {
      throw StateError('Rewrite upgrade has not completed');
    }
    if (!await _hasCurrentMarker()) {
      throw StateError('Rewrite completion marker is missing');
    }
    await _deleteJournalCandidates();
    await _notify('completion-acknowledged');
  }

  Future<void> _performReset(List<String> preservedRoots) async {
    final protected = preservedRoots.map(_normalizeAbsolute).toSet();
    for (final name in _dataResetNames) {
      final target = p.join(dataDirectory.path, name);
      if (_isProtectedPath(target, protected)) {
        throw StateError('Refusing to reset protected local path: $target');
      }
      await _deleteEntityIfExists(target);
      await _notify('deleted-data:$name');
    }

    for (final databaseName in _databaseResetNames) {
      for (final suffix in const ['', '-wal', '-shm', '-journal']) {
        final name = '$databaseName$suffix';
        final target = p.join(dataDirectory.path, name);
        if (_isProtectedPath(target, protected)) {
          throw StateError('Refusing to reset protected local path: $target');
        }
        await _deleteEntityIfExists(target);
      }
      await _notify('deleted-database:$databaseName');
    }

    await _clearCacheDirectory(protected);
  }

  Future<void> _clearCacheDirectory(Set<String> protectedRoots) async {
    final dataRoot = _normalizeAbsolute(dataDirectory.path);
    final cacheRoot = _normalizeAbsolute(cacheDirectory.path);
    if (cacheRoot == dataRoot ||
        p.isWithin(cacheRoot, dataRoot) ||
        p.isWithin(dataRoot, cacheRoot)) {
      throw StateError(
        'Application data and cache directories must not contain each other',
      );
    }
    if (!await cacheDirectory.exists()) return;
    await for (final entity in cacheDirectory.list(followLinks: false)) {
      if (p.basename(entity.path) == 'image_favorites' ||
          _isProtectedPath(entity.path, protectedRoots)) {
        continue;
      }
      await _deleteEntityIfExists(entity.path);
    }
    await _notify('cache-cleared');
  }

  Future<List<String>> _discoverPreservedLocalRoots() async {
    final roots = <String>{
      _normalizeAbsolute(p.join(dataDirectory.path, 'local')),
      ..._additionalPreservedLocalRoots,
    };
    final configuredPath = File(p.join(dataDirectory.path, 'local_path'));
    if (await configuredPath.exists()) {
      try {
        final value = (await configuredPath.readAsString()).trim();
        if (value.isNotEmpty) roots.add(_normalizeAbsolute(value));
      } catch (_) {
        // Preserve the managed root even if the optional pointer is malformed.
      }
    }
    await _addIndexedAbsoluteLocalRoots(roots);
    return roots.toList(growable: false)..sort();
  }

  Future<void> _addIndexedAbsoluteLocalRoots(Set<String> roots) async {
    final file = File(p.join(dataDirectory.path, 'local.db'));
    if (!await file.exists()) return;
    Database? database;
    try {
      database = sqlite3.open(file.path, mode: OpenMode.readOnly);
      final hasComics = database
          .select(
            "SELECT 1 FROM sqlite_master "
            "WHERE type = 'table' AND name = 'comics' LIMIT 1;",
          )
          .isNotEmpty;
      if (!hasComics) {
        throw const FormatException('Local comic index has no comics table');
      }
      for (final row in database.select('SELECT directory FROM comics;')) {
        final directory = row['directory']?.toString().trim();
        if (directory != null &&
            directory.isNotEmpty &&
            p.isAbsolute(directory)) {
          roots.add(_normalizeAbsolute(directory));
        }
      }
    } catch (error) {
      throw FormatException('Failed to inspect local comic index', error);
    } finally {
      database?.close();
    }
  }

  Future<bool> _containsLegacyData() async {
    for (final name in _legacyEvidenceNames) {
      final type = await FileSystemEntity.type(
        p.join(dataDirectory.path, name),
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound) return true;
    }

    final managedLocal = Directory(p.join(dataDirectory.path, 'local'));
    if (await managedLocal.exists()) {
      await for (final entity in managedLocal.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name != '.nomedia' && name != 'venera_test') return true;
      }
    }
    final favoriteImages = Directory(
      p.join(cacheDirectory.path, 'image_favorites'),
    );
    if (await favoriteImages.exists() && !await favoriteImages.list().isEmpty) {
      return true;
    }
    return false;
  }

  String _validateExternalBackupPath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Backup destination is missing');
    }
    final looksLikeWindowsPath = RegExp(r'^[A-Za-z]:[/\\]').hasMatch(trimmed);
    final uri = looksLikeWindowsPath ? null : Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme && uri.scheme.toLowerCase() != 'file') {
      return trimmed;
    }
    var localPath = trimmed;
    if (uri != null && uri.scheme.toLowerCase() == 'file') {
      try {
        localPath = uri.toFilePath(windows: Platform.isWindows);
      } catch (_) {
        throw const FormatException('Invalid backup destination');
      }
    }
    if (!p.isAbsolute(localPath)) {
      throw const FormatException('Backup destination must be absolute');
    }
    final normalized = _normalizeAbsolute(localPath);
    final dataRoot = _normalizeAbsolute(dataDirectory.path);
    final cacheRoot = _normalizeAbsolute(cacheDirectory.path);
    if (_sameOrWithin(dataRoot, normalized) ||
        _sameOrWithin(cacheRoot, normalized)) {
      throw const FormatException(
        'Backup must be saved outside application data and cache directories',
      );
    }
    return normalized;
  }

  Future<bool> _hasCurrentMarker() async {
    if (!await _marker.exists()) return false;
    try {
      final value = jsonDecode(await _marker.readAsString());
      return value is Map &&
          value['format'] == 'venera-rewrite' &&
          value['targetVersion'] is int &&
          (value['targetVersion'] as int) >= targetVersion;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeCompletionMarker() async {
    final temp = File('${_marker.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'format': 'venera-rewrite',
        'targetVersion': targetVersion,
        'completedAt': _clock().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    if (await _marker.exists()) await _marker.delete();
    await temp.rename(_marker.path);
  }

  Future<void> _writeJournal(_RewriteUpgradeJournal journal) async {
    await _journalTemp.writeAsString(jsonEncode(journal.toJson()), flush: true);
    await _journalPrevious.deleteIfExists();
    if (await _journal.exists()) {
      await _journal.rename(_journalPrevious.path);
    }
    await _journalTemp.rename(_journal.path);
  }

  Future<_RewriteUpgradeJournal?> _readLatestJournal() async {
    final candidates = <_RewriteUpgradeJournal>[];
    for (final file in [_journal, _journalTemp, _journalPrevious]) {
      if (!await file.exists()) continue;
      try {
        final parsed = _RewriteUpgradeJournal.tryParse(
          jsonDecode(await file.readAsString()),
        );
        if (parsed != null) candidates.add(parsed);
      } catch (_) {
        // Another durable candidate may still contain the last valid state.
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.sequence.compareTo(a.sequence));
    return candidates.first;
  }

  Future<bool> _hasInvalidJournalArtifacts() async {
    for (final file in [_journal, _journalTemp, _journalPrevious]) {
      if (await file.exists()) return true;
    }
    return false;
  }

  Future<void> _deleteJournalCandidates() async {
    await _journal.deleteIfExists();
    await _journalTemp.deleteIfExists();
    await _journalPrevious.deleteIfExists();
  }

  Future<void> _notify(String step) async => _afterStep?.call(step);
}

const Set<String> _databaseResetNames = {
  'history.db',
  'local_favorite.db',
  'cookie.db',
  'local.db',
  'cache.db',
  'comic_details.db',
  'venera.db',
};

const Set<String> _dataResetNames = {
  'appdata.json',
  'appdata.json.tmp',
  'appdata.json.bak',
  'syncdata.json',
  'syncdata.json.tmp',
  'syncdata.json.bak',
  'implicitData.json',
  'implicitData.json.tmp',
  'implicitData.json.bak',
  'downloading_tasks.json',
  'downloading_tasks.json.tmp',
  'downloading_tasks.json.bak',
  'comic_source',
  'favorite_cover',
  '.venera-backup-import.incoming',
  '.venera-backup-import.bak',
  '.venera-backup-import.json',
  '.venera-backup-import.json.tmp',
  '.venera-backup-import.json.previous',
};

const Set<String> _legacyEvidenceNames = {
  'appdata.json',
  'appdata.json.bak',
  'history.db',
  'local_favorite.db',
  'cookie.db',
  'local.db',
  'local_path',
  'comic_source',
  'downloading_tasks.json',
  'venera.db',
};

final class _RewriteUpgradeJournal {
  const _RewriteUpgradeJournal({
    required this.targetVersion,
    required this.phase,
    required this.sequence,
    required this.savedBackupPath,
    required this.backupAppVersion,
    required this.backupCreatedAt,
    required this.backupFingerprint,
    required this.verifiedEntryPaths,
    required this.preservedLocalRoots,
  });

  final int targetVersion;
  final RewriteUpgradePhase phase;
  final int sequence;
  final String savedBackupPath;
  final String backupAppVersion;
  final DateTime backupCreatedAt;
  final String backupFingerprint;
  final List<String> verifiedEntryPaths;
  final List<String> preservedLocalRoots;

  _RewriteUpgradeJournal next(RewriteUpgradePhase nextPhase) =>
      _RewriteUpgradeJournal(
        targetVersion: targetVersion,
        phase: nextPhase,
        sequence: sequence + 1,
        savedBackupPath: savedBackupPath,
        backupAppVersion: backupAppVersion,
        backupCreatedAt: backupCreatedAt,
        backupFingerprint: backupFingerprint,
        verifiedEntryPaths: verifiedEntryPaths,
        preservedLocalRoots: preservedLocalRoots,
      );

  RewriteUpgradeSnapshot toSnapshot() => RewriteUpgradeSnapshot(
    phase: phase,
    savedBackupPath: savedBackupPath,
    backupAppVersion: backupAppVersion,
    backupCreatedAt: backupCreatedAt,
    backupFingerprint: backupFingerprint,
    preservedLocalRoots: List.unmodifiable(preservedLocalRoots),
  );

  Map<String, Object?> toJson() => {
    'format': 'venera-rewrite-upgrade',
    'journalVersion': 1,
    'targetVersion': targetVersion,
    'phase': phase.name,
    'sequence': sequence,
    'savedBackupPath': savedBackupPath,
    'backupAppVersion': backupAppVersion,
    'backupCreatedAt': backupCreatedAt.toUtc().toIso8601String(),
    'backupFingerprint': backupFingerprint,
    'verifiedEntryPaths': verifiedEntryPaths,
    'preservedLocalRoots': preservedLocalRoots,
  };

  static _RewriteUpgradeJournal? tryParse(Object? value) {
    if (value is! Map ||
        value['format'] != 'venera-rewrite-upgrade' ||
        value['journalVersion'] != 1 ||
        value['targetVersion'] is! int ||
        value['sequence'] is! int ||
        value['savedBackupPath'] is! String ||
        value['backupAppVersion'] is! String ||
        value['backupFingerprint'] is! String ||
        value['verifiedEntryPaths'] is! List ||
        value['preservedLocalRoots'] is! List) {
      return null;
    }
    final phase = RewriteUpgradePhase.values
        .where((candidate) => candidate.name == value['phase'])
        .firstOrNull;
    final createdAt = DateTime.tryParse(
      value['backupCreatedAt']?.toString() ?? '',
    );
    final roots = (value['preservedLocalRoots'] as List)
        .whereType<String>()
        .toList(growable: false);
    final verifiedEntries = (value['verifiedEntryPaths'] as List)
        .whereType<String>()
        .toList(growable: false);
    if (phase == null ||
        phase == RewriteUpgradePhase.notRequired ||
        phase == RewriteUpgradePhase.backupRequired ||
        (value['targetVersion'] as int) < 1 ||
        (value['sequence'] as int) < 1 ||
        (value['savedBackupPath'] as String).isEmpty ||
        (value['backupAppVersion'] as String).isEmpty ||
        !RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(value['backupFingerprint'] as String) ||
        createdAt == null ||
        verifiedEntries.length !=
            (value['verifiedEntryPaths'] as List).length ||
        !verifiedEntries.toSet().containsAll(
          RewriteUpgradeCoordinator.requiredBackupEntryPaths,
        ) ||
        roots.length != (value['preservedLocalRoots'] as List).length) {
      return null;
    }
    return _RewriteUpgradeJournal(
      targetVersion: value['targetVersion'] as int,
      phase: phase,
      sequence: value['sequence'] as int,
      savedBackupPath: value['savedBackupPath'] as String,
      backupAppVersion: value['backupAppVersion'] as String,
      backupCreatedAt: createdAt,
      backupFingerprint: value['backupFingerprint'] as String,
      verifiedEntryPaths: verifiedEntries,
      preservedLocalRoots: roots,
    );
  }
}

String _normalizeAbsolute(String value) {
  var normalized = p.normalize(p.absolute(value));
  if (Platform.isWindows) normalized = normalized.toLowerCase();
  return normalized;
}

bool _sameOrWithin(String root, String candidate) =>
    candidate == root || p.isWithin(root, candidate);

bool _isProtectedPath(String candidate, Set<String> protectedRoots) {
  final normalized = _normalizeAbsolute(candidate);
  return protectedRoots.any(
    (root) =>
        _sameOrWithin(root, normalized) || _sameOrWithin(normalized, root),
  );
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

extension on FileSystemEntity {
  Future<void> deleteIfExists({bool recursive = false}) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    await delete(recursive: recursive);
  }
}
