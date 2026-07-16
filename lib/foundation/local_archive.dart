import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:archive/archive_io.dart' as archive_io;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

/// On-disk state of a locally downloaded comic.
enum LocalStorageState { loose, archived, expanded, dirty, missing, error }

enum LocalArchiveOperation {
  inspect,
  compress,
  verify,
  restore,
  finalize,
  cleanup,
  reconcile,
}

class LocalArchiveProgress {
  const LocalArchiveProgress({
    required this.operation,
    required this.completedFiles,
    required this.totalFiles,
    this.currentPath,
    this.completedBytes,
    this.totalBytes,
  });

  final LocalArchiveOperation operation;
  final int completedFiles;
  final int totalFiles;
  final String? currentPath;
  final int? completedBytes;
  final int? totalBytes;

  double get fraction {
    final bytes = completedBytes;
    final bytesTotal = totalBytes;
    if (bytes != null && bytesTotal != null && bytesTotal > 0) {
      return bytes / bytesTotal;
    }
    return totalFiles == 0 ? 0 : completedFiles / totalFiles;
  }
}

typedef LocalArchiveProgressCallback =
    void Function(LocalArchiveProgress value);

double localArchiveOverallProgress(LocalArchiveProgress progress) {
  final fraction = progress.fraction.clamp(0.0, 1.0);
  return switch (progress.operation) {
    LocalArchiveOperation.inspect => fraction * 0.15,
    LocalArchiveOperation.compress => 0.15 + fraction * 0.45,
    LocalArchiveOperation.verify => 0.6 + fraction * 0.28,
    LocalArchiveOperation.reconcile => 0.88 + fraction * 0.02,
    LocalArchiveOperation.restore => fraction * 0.85,
    LocalArchiveOperation.finalize => 0.85 + fraction * 0.15,
    LocalArchiveOperation.cleanup => 0.9 + fraction * 0.1,
  };
}

Duration? estimateLocalArchiveRemaining({
  required Duration elapsed,
  required double progress,
}) {
  if (elapsed < const Duration(seconds: 2) ||
      !progress.isFinite ||
      progress < 0.01 ||
      progress >= 1) {
    return null;
  }
  final remainingMillis = (elapsed.inMilliseconds * (1 - progress) / progress)
      .round();
  if (remainingMillis <= 0 ||
      remainingMillis > const Duration(days: 7).inMilliseconds) {
    return null;
  }
  return Duration(milliseconds: remainingMillis);
}

String formatLocalArchiveRemaining(Duration value) {
  final seconds = value.inSeconds.clamp(0, const Duration(days: 7).inSeconds);
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}

String localArchiveProgressStageKey(LocalArchiveOperation operation) {
  return switch (operation) {
    LocalArchiveOperation.inspect => 'Scanning files',
    LocalArchiveOperation.compress => 'Writing compressed file',
    LocalArchiveOperation.verify => 'Verifying compressed file',
    LocalArchiveOperation.restore => 'Opening compressed comic',
    LocalArchiveOperation.finalize => 'Preparing comic',
    LocalArchiveOperation.cleanup => 'Cleaning source files',
    LocalArchiveOperation.reconcile => 'Checking source files',
  };
}

class LocalArchiveCancellationToken {
  bool _isCancelled = false;
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _isCancelled;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelled.complete();
  }

  void throwIfCancelled() {
    if (_isCancelled) {
      throw const LocalArchiveCancelledException();
    }
  }
}

class LocalArchiveException implements Exception {
  const LocalArchiveException(this.message);

  final String message;

  @override
  String toString() => 'LocalArchiveException: $message';
}

class LocalArchiveCancelledException extends LocalArchiveException {
  const LocalArchiveCancelledException() : super('Operation cancelled');
}

/// Keeps destructive archive cleanup from interleaving with a downloader that
/// is still expected to create more files for the same comic.
class LocalArchiveWriteLease {
  LocalArchiveWriteLease._(this._release);

  final void Function() _release;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _release();
  }
}

class ArchiveManifestEntry {
  const ArchiveManifestEntry({
    required this.path,
    required this.size,
    required this.modifiedAtMillis,
    required this.sha256,
  });

  final String path;
  final int size;
  final int modifiedAtMillis;
  final String sha256;

  Map<String, Object> toJson() => {
    'path': path,
    'size': size,
    'modifiedAt': modifiedAtMillis,
    'sha256': sha256,
  };

  factory ArchiveManifestEntry.fromJson(Map<String, dynamic> json) {
    final path = normalizeLocalArchiveEntryPath(json['path']?.toString() ?? '');
    final size = _readNonNegativeInt(json['size'], field: 'size');
    final modifiedAt = _readNonNegativeInt(
      json['modifiedAt'],
      field: 'modifiedAt',
    );
    final hash = json['sha256']?.toString().toLowerCase() ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid archive entry sha256');
    }
    return ArchiveManifestEntry(
      path: path,
      size: size,
      modifiedAtMillis: modifiedAt,
      sha256: hash,
    );
  }
}

class ArchiveManifest {
  const ArchiveManifest({
    required this.version,
    required this.comicId,
    required this.sourceKey,
    required this.comicType,
    required this.createdAtMillis,
    required this.entries,
  });

  static const currentVersion = 1;

  final int version;
  final String comicId;
  final String sourceKey;
  final int comicType;
  final int createdAtMillis;
  final List<ArchiveManifestEntry> entries;

  int get uncompressedBytes => entries.fold(0, (sum, item) => sum + item.size);

  String get identity =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();

  Map<String, Object> toJson() => {
    'version': version,
    'comic': {'id': comicId, 'sourceKey': sourceKey, 'comicType': comicType},
    'createdAt': createdAtMillis,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };

  factory ArchiveManifest.fromJson(Map<String, dynamic> json) {
    final version = _readNonNegativeInt(json['version'], field: 'version');
    if (version != currentVersion) {
      throw FormatException('Unsupported archive manifest version: $version');
    }
    final comicValue = json['comic'];
    if (comicValue is! Map) {
      throw const FormatException('Invalid archive comic identity');
    }
    final comic = Map<String, dynamic>.from(comicValue);
    final entriesValue = json['entries'];
    if (entriesValue is! List || entriesValue.isEmpty) {
      throw const FormatException('Archive manifest has no entries');
    }
    final entries = <ArchiveManifestEntry>[];
    final paths = <String>{};
    for (final value in entriesValue) {
      if (value is! Map) {
        throw const FormatException('Invalid archive manifest entry');
      }
      final entry = ArchiveManifestEntry.fromJson(
        Map<String, dynamic>.from(value),
      );
      final pathKey = entry.path.toLowerCase();
      if (!paths.add(pathKey)) {
        throw FormatException('Duplicate archive entry: ${entry.path}');
      }
      entries.add(entry);
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    return ArchiveManifest(
      version: version,
      comicId: comic['id']?.toString() ?? '',
      sourceKey: comic['sourceKey']?.toString() ?? '',
      comicType: _readInt(comic['comicType'], field: 'comicType'),
      createdAtMillis: _readNonNegativeInt(
        json['createdAt'],
        field: 'createdAt',
      ),
      entries: List.unmodifiable(entries),
    );
  }
}

class LocalArchiveSnapshot {
  const LocalArchiveSnapshot({
    required this.state,
    required this.archiveExists,
    required this.archiveBytes,
    required this.looseBytes,
    this.manifest,
    this.errorMessage,
  });

  final LocalStorageState state;
  final bool archiveExists;
  final int archiveBytes;
  final int looseBytes;
  final ArchiveManifest? manifest;
  final String? errorMessage;

  int get savedBytes {
    final sourceBytes = manifest?.uncompressedBytes ?? looseBytes;
    return sourceBytes > archiveBytes ? sourceBytes - archiveBytes : 0;
  }
}

class LocalArchiveResult extends LocalArchiveSnapshot {
  const LocalArchiveResult({
    required super.state,
    required super.archiveExists,
    required super.archiveBytes,
    required super.looseBytes,
    required this.rebuiltArchive,
    super.manifest,
    super.errorMessage,
  });

  final bool rebuiltArchive;
}

@visibleForTesting
String normalizeLocalArchiveEntryPath(String value) {
  if (value.isEmpty || value.contains('\u0000')) {
    throw const FormatException('Empty archive entry path');
  }
  if (value.contains('\\')) {
    throw const FormatException('Backslashes are not allowed in archive paths');
  }
  if (value.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(value)) {
    throw const FormatException('Absolute archive entry path');
  }
  final segments = value.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw const FormatException('Unsafe archive entry path');
  }
  final normalized = p.posix.normalize(value);
  if (normalized != value || normalized.startsWith('../')) {
    throw const FormatException('Unsafe archive entry path');
  }
  return normalized;
}

/// Owns the versioned archive stored under `<comic>/.venera/archive.zip`.
///
/// Operations are globally serialized so compression, opening, download
/// writes, and destructive cleanup cannot interleave. The cover and `.venera`
/// metadata directory are never added to the compressed file.
class LocalArchiveService {
  LocalArchiveService._({String? libraryRootOverride})
    : _libraryRootOverride = libraryRootOverride;

  static final LocalArchiveService _instance = LocalArchiveService._();

  factory LocalArchiveService() => _instance;

  @visibleForTesting
  factory LocalArchiveService.forTesting({required String libraryRoot}) {
    return LocalArchiveService._(libraryRootOverride: libraryRoot);
  }

  static const metadataDirectoryName = '.venera';
  static const archiveFileName = 'archive.zip';
  static const manifestFileName = 'manifest.json';

  final String? _libraryRootOverride;
  Future<void> _operationQueue = Future<void>.value();
  final Map<String, _ActiveWriterState> _activeWriters = {};

  Future<LocalArchiveSnapshot> inspect(LocalComic comic) {
    return _runExclusive(() async {
      try {
        final root = _comicRoot(comic);
        if (await root.exists()) {
          await _recoverInterruptedCommit(root, comic);
          await _removeStaleOperationFiles(root);
        }
        return await _inspectRoot(root, comic);
      } catch (error) {
        return LocalArchiveSnapshot(
          state: LocalStorageState.error,
          archiveExists: false,
          archiveBytes: 0,
          looseBytes: 0,
          errorMessage: error.toString(),
        );
      }
    });
  }

  Future<LocalArchiveResult> compress(
    LocalComic comic, {
    LocalArchiveCancellationToken? cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  }) {
    return _runExclusive(() async {
      final token = cancellationToken ?? LocalArchiveCancellationToken();
      final root = _comicRoot(comic);
      _assertComicIdentity(root, comic);
      await _waitForActiveWriters(root, token);
      if (!await root.exists()) {
        throw const LocalArchiveException('Comic directory does not exist');
      }
      await _recoverInterruptedCommit(root, comic);
      token.throwIfCancelled();

      final pair = await _readValidPair(root, comic, throwOnInvalid: true);
      var files = await _scanLooseFiles(
        root,
        comic,
        hashFiles: pair != null,
        cancellationToken: token,
        // For a new compressed file this is only a quick inventory pass; the
        // following hash pass reports the real scan progress. Reporting both
        // would jump to 15% and then appear frozen while hashing.
        onProgress: pair == null ? null : onProgress,
        operation: LocalArchiveOperation.inspect,
      );

      if (pair != null && files.isEmpty) {
        await _clearStateMarkers(root);
        return _resultFromSnapshot(
          await _inspectRoot(root, comic),
          rebuiltArchive: false,
        );
      }

      if (pair != null) {
        final relation = _compareFiles(files, pair.manifest, requireAll: true);
        final dirty = await _dirtyMarker(root).exists();
        final cleanupMatches = await _markerMatches(
          _cleanupMarker(root),
          pair.manifest.identity,
        );
        final safePartialCleanup =
            cleanupMatches &&
            _compareFiles(files, pair.manifest, requireAll: false);
        if (!dirty && (relation || safePartialCleanup)) {
          await _writeMarker(_cleanupMarker(root), pair.manifest.identity);
          await _deleteVerifiedLooseFiles(
            root,
            comic,
            files,
            pair.manifest,
            token,
            onProgress,
          );
          await _clearStateMarkers(root);
          return _resultFromSnapshot(
            await _inspectRoot(root, comic),
            rebuiltArchive: false,
          );
        }

        // A previous verified cleanup may have removed part of the old loose
        // tree before another writer marked the comic dirty. A marker-free
        // mismatch can also come from an external file copy/edit that bypassed
        // [prepareForWrite]. In both cases restore missing archived files first
        // (while preserving loose edits), so rebuilding cannot silently drop
        // chapters that currently exist only in the retained ZIP.
        if (cleanupMatches || !dirty) {
          await _restorePair(
            root,
            comic,
            pair,
            token,
            onProgress,
            preserveExisting: true,
          );
          await _cleanupMarker(root).deleteIgnoreError();
          files = await _scanLooseFiles(
            root,
            comic,
            hashFiles: true,
            cancellationToken: token,
            onProgress: onProgress,
            operation: LocalArchiveOperation.inspect,
          );
        }
      }

      if (files.isEmpty) {
        throw const LocalArchiveException('Comic has no archivable files');
      }

      // A new compressed file still needs its first content hash pass. When a
      // previous compressed file exists, the initial scan (or the post-restore
      // scan above) already produced verified hashes, so do not read every
      // page again.
      if (pair == null) {
        files = await _scanLooseFiles(
          root,
          comic,
          hashFiles: true,
          cancellationToken: token,
          onProgress: onProgress,
          operation: LocalArchiveOperation.inspect,
        );
      }
      final manifest = ArchiveManifest(
        version: ArchiveManifest.currentVersion,
        comicId: comic.id,
        sourceKey: comic.sourceKey,
        comicType: comic.comicType.value,
        createdAtMillis: DateTime.now().millisecondsSinceEpoch,
        entries: List.unmodifiable(files.map((file) => file.toManifestEntry())),
      );

      final metadata = await _metadataDirectory(root).create(recursive: true);
      final operationId = const Uuid().v4();
      final archiveTemp = File(
        p.join(metadata.path, '$archiveFileName.tmp-$operationId'),
      );
      final manifestTemp = File(
        p.join(metadata.path, '$manifestFileName.tmp-$operationId'),
      );
      try {
        token.throwIfCancelled();
        await _writeZip(archiveTemp, files, token, onProgress);
        // Never remove the loose originals until every generated ZIP entry
        // has been read back and matched against the source checksum.
        await _validateArchive(
          archiveTemp,
          manifest,
          verifyContent: true,
          cancellationToken: token,
          onProgress: onProgress,
        );

        // Detect source changes that happened while the native writer was
        // active. The old archive and loose files remain untouched on failure.
        final afterWrite = await _scanLooseFiles(
          root,
          comic,
          // The ZIP was already checked against the pre-write SHA-256
          // manifest. A metadata pass is enough to detect normal concurrent
          // edits before cleanup and avoids reading every page a fourth time.
          hashFiles: false,
          cancellationToken: token,
          onProgress: onProgress,
          operation: LocalArchiveOperation.reconcile,
        );
        if (!_sameFileMetadata(files, afterWrite)) {
          throw const LocalArchiveException(
            'Comic files changed while compression was running',
          );
        }
        files = afterWrite;

        await manifestTemp.writeAsString(
          jsonEncode(manifest.toJson()),
          encoding: utf8,
          flush: true,
        );
        await _commitPair(root, comic, archiveTemp, manifestTemp, manifest);
        // The committed manifest now includes every app-managed write that
        // caused the previous dirty marker. Remove it before cleanup; a writer
        // racing with cleanup will create it again and stop deletion at the
        // next file boundary.
        await _dirtyMarker(root).deleteIgnoreError();
        await _writeMarker(_cleanupMarker(root), manifest.identity);
        await _deleteVerifiedLooseFiles(
          root,
          comic,
          files,
          manifest,
          token,
          onProgress,
        );
        await _clearStateMarkers(root);
        return _resultFromSnapshot(
          await _inspectRoot(root, comic),
          rebuiltArchive: true,
        );
      } finally {
        await archiveTemp.deleteIgnoreError();
        await manifestTemp.deleteIgnoreError();
      }
    });
  }

  Future<LocalArchiveResult> restore(
    LocalComic comic, {
    LocalArchiveCancellationToken? cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  }) {
    return _runExclusive(() async {
      final token = cancellationToken ?? LocalArchiveCancellationToken();
      final root = _comicRoot(comic);
      _assertComicIdentity(root, comic);
      if (!await root.exists()) {
        throw const LocalArchiveException('Comic directory does not exist');
      }
      await _recoverInterruptedCommit(root, comic);
      final pair = await _readValidPair(root, comic, throwOnInvalid: true);
      if (pair == null) {
        return _resultFromSnapshot(
          await _inspectRoot(root, comic),
          rebuiltArchive: false,
        );
      }
      // A dirty tree is authoritative: missing files may represent an
      // intentional chapter deletion, so restoring the old ZIP here would
      // resurrect content. Writers must call restore before markDirty.
      if (await _dirtyMarker(root).exists()) {
        return _resultFromSnapshot(
          await _inspectRoot(root, comic),
          rebuiltArchive: false,
        );
      }
      if (await _markerMatches(_expandedMarker(root), pair.manifest.identity) &&
          !await _cleanupMarker(root).exists()) {
        return _resultFromSnapshot(
          await _inspectRoot(root, comic),
          rebuiltArchive: false,
        );
      }
      await _restorePair(
        root,
        comic,
        pair,
        token,
        onProgress,
        preserveExisting: true,
      );
      await _cleanupMarker(root).deleteIgnoreError();
      await _writeMarker(_expandedMarker(root), pair.manifest.identity);
      return _resultFromSnapshot(
        await _inspectRoot(root, comic),
        rebuiltArchive: false,
      );
    });
  }

  /// Restores the archived tree, when necessary, and marks it dirty as one
  /// serialized operation. Long-running writers should await this before
  /// their first write; short destructive mutations should use
  /// [runPreparedMutation] so compression cannot interleave with the change.
  Future<LocalArchiveResult> prepareForWrite(
    LocalComic comic, {
    LocalArchiveCancellationToken? cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  }) {
    return _runExclusive(
      () => _prepareForWriteUnlocked(
        comic,
        cancellationToken ?? LocalArchiveCancellationToken(),
        onProgress,
      ),
    );
  }

  /// Expands and marks the comic dirty, then holds an in-memory lease until
  /// the caller finishes a long-running series of writes. Compression waits
  /// for all leases on the same comic, while reads and progress updates remain
  /// available.
  Future<LocalArchiveWriteLease> beginWrite(
    LocalComic comic, {
    LocalArchiveCancellationToken? cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  }) {
    return _runExclusive(() async {
      await _prepareForWriteUnlocked(
        comic,
        cancellationToken ?? LocalArchiveCancellationToken(),
        onProgress,
      );
      final root = _comicRoot(comic);
      final key = _writerKey(root);
      final state = _activeWriters.putIfAbsent(key, _ActiveWriterState.new);
      state.count++;
      return LocalArchiveWriteLease._(() => _releaseWriter(key, state));
    });
  }

  /// Runs a short filesystem mutation while holding the archive queue after
  /// expansion and dirty marking. This is intended for chapter deletion and
  /// similarly bounded operations; network downloads must not hold the queue.
  Future<T> runPreparedMutation<T>(
    LocalComic comic,
    Future<T> Function() mutation, {
    LocalArchiveCancellationToken? cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  }) {
    return _runExclusive(() async {
      await _prepareForWriteUnlocked(
        comic,
        cancellationToken ?? LocalArchiveCancellationToken(),
        onProgress,
      );
      return mutation();
    });
  }

  /// Marks an expanded archive as modified before an app-managed file write.
  Future<void> markDirty(LocalComic comic) {
    return _runExclusive(() async {
      final root = _comicRoot(comic);
      _assertComicIdentity(root, comic);
      if (!await root.exists()) {
        throw const LocalArchiveException('Comic directory does not exist');
      }
      if (await _archiveFile(root).exists()) {
        await _markDirtyRoot(root);
      }
    });
  }

  /// Recovers an interrupted pair commit and finishes only a previously
  /// verified loose-file cleanup. It never deletes dirty content.
  Future<LocalArchiveSnapshot> reconcile(LocalComic comic) {
    return _runExclusive(() async {
      final root = _comicRoot(comic);
      _assertComicIdentity(root, comic);
      if (!await root.exists()) {
        return const LocalArchiveSnapshot(
          state: LocalStorageState.missing,
          archiveExists: false,
          archiveBytes: 0,
          looseBytes: 0,
        );
      }
      await _recoverInterruptedCommit(root, comic);
      await _removeStaleOperationFiles(root);
      final pair = await _readValidPair(root, comic, throwOnInvalid: false);
      if (pair != null &&
          !await _dirtyMarker(root).exists() &&
          await _markerMatches(_cleanupMarker(root), pair.manifest.identity)) {
        final files = await _scanLooseFiles(
          root,
          comic,
          hashFiles: true,
          cancellationToken: LocalArchiveCancellationToken(),
          operation: LocalArchiveOperation.reconcile,
        );
        if (_compareFiles(files, pair.manifest, requireAll: false)) {
          await _deleteVerifiedLooseFiles(
            root,
            comic,
            files,
            pair.manifest,
            LocalArchiveCancellationToken(),
            null,
          );
          await _clearStateMarkers(root);
        }
      }
      return _inspectRoot(root, comic);
    });
  }

  File archiveFileFor(LocalComic comic) => _archiveFile(_comicRoot(comic));

  File manifestFileFor(LocalComic comic) => _manifestFile(_comicRoot(comic));

  /// Whether [comic] is a normal directory contained by the app-managed
  /// local library. Linked and externally referenced comics are never valid
  /// archive targets.
  bool canManage(LocalComic comic) {
    try {
      _comicRoot(comic);
      return true;
    } on LocalArchiveException {
      return false;
    }
  }

  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _operationQueue = _operationQueue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _waitForActiveWriters(
    Directory root,
    LocalArchiveCancellationToken token,
  ) async {
    final key = _writerKey(root);
    while (true) {
      final state = _activeWriters[key];
      if (state == null || state.count == 0) return;
      await Future.any([state.idle.future, token.whenCancelled]);
      token.throwIfCancelled();
    }
  }

  void _releaseWriter(String key, _ActiveWriterState expected) {
    final state = _activeWriters[key];
    if (!identical(state, expected) || state == null || state.count == 0) {
      return;
    }
    state.count--;
    if (state.count == 0) {
      _activeWriters.remove(key);
      if (!state.idle.isCompleted) {
        state.idle.complete();
      }
    }
  }

  String _writerKey(Directory root) => _normalizedComparablePath(root.path);

  Future<LocalArchiveResult> _prepareForWriteUnlocked(
    LocalComic comic,
    LocalArchiveCancellationToken token,
    LocalArchiveProgressCallback? onProgress,
  ) async {
    final root = _comicRoot(comic);
    _assertComicIdentity(root, comic);
    if (!await root.exists()) {
      throw const LocalArchiveException('Comic directory does not exist');
    }
    await _recoverInterruptedCommit(root, comic);
    token.throwIfCancelled();
    final pair = await _readValidPair(root, comic, throwOnInvalid: true);
    if (pair == null) {
      return _resultFromSnapshot(
        await _inspectRoot(root, comic),
        rebuiltArchive: false,
      );
    }

    if (!await _dirtyMarker(root).exists()) {
      final alreadyExpanded =
          await _markerMatches(_expandedMarker(root), pair.manifest.identity) &&
          !await _cleanupMarker(root).exists();
      if (!alreadyExpanded) {
        await _restorePair(
          root,
          comic,
          pair,
          token,
          onProgress,
          preserveExisting: true,
        );
        await _cleanupMarker(root).deleteIgnoreError();
        await _writeMarker(_expandedMarker(root), pair.manifest.identity);
      }
      await _markDirtyRoot(root);
    }
    return _resultFromSnapshot(
      await _inspectRoot(root, comic),
      rebuiltArchive: false,
    );
  }

  Directory _comicRoot(LocalComic comic) {
    final libraryRoot = p.normalize(
      p.absolute(_libraryRootOverride ?? LocalManager().path),
    );
    final comicRoot = p.normalize(p.absolute(comic.baseDir));
    if (comicRoot == libraryRoot || !p.isWithin(libraryRoot, comicRoot)) {
      throw LocalArchiveException(
        'Refusing to archive a comic outside the local library: $comicRoot',
      );
    }
    if (FileSystemEntity.typeSync(comicRoot, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const LocalArchiveException('Comic directory cannot be a link');
    }
    // A lexically contained path may still escape through a linked ancestor
    // (for example `<library>/link/external-comic`). Resolve both existing
    // paths before allowing any archive write or cleanup.
    if (Directory(comicRoot).existsSync()) {
      try {
        final resolvedLibrary = p.normalize(
          Directory(libraryRoot).resolveSymbolicLinksSync(),
        );
        final resolvedComic = p.normalize(
          Directory(comicRoot).resolveSymbolicLinksSync(),
        );
        if (resolvedComic == resolvedLibrary ||
            !p.isWithin(resolvedLibrary, resolvedComic)) {
          throw LocalArchiveException(
            'Refusing to archive a linked external comic: $comicRoot',
          );
        }
      } on LocalArchiveException {
        rethrow;
      } on FileSystemException catch (error) {
        throw LocalArchiveException(
          'Unable to resolve comic archive path: $error',
        );
      }
    }
    return Directory(comicRoot);
  }

  void _assertComicIdentity(Directory root, LocalComic comic) {
    if (comic.id.isEmpty || comic.sourceKey.isEmpty || root.path.isEmpty) {
      throw const LocalArchiveException('Invalid comic identity');
    }
  }

  Directory _metadataDirectory(Directory root) =>
      Directory(p.join(root.path, metadataDirectoryName));

  File _archiveFile(Directory root) =>
      File(p.join(root.path, metadataDirectoryName, archiveFileName));

  File _manifestFile(Directory root) =>
      File(p.join(root.path, metadataDirectoryName, manifestFileName));

  File _archiveBackup(Directory root) => File('${_archiveFile(root).path}.bak');

  File _manifestBackup(Directory root) =>
      File('${_manifestFile(root).path}.bak');

  File _expandedMarker(Directory root) =>
      File(p.join(root.path, metadataDirectoryName, 'expanded.json'));

  File _dirtyMarker(Directory root) =>
      File(p.join(root.path, metadataDirectoryName, 'dirty'));

  File _cleanupMarker(Directory root) =>
      File(p.join(root.path, metadataDirectoryName, 'cleanup.json'));

  Future<LocalArchiveSnapshot> _inspectRoot(
    Directory root,
    LocalComic comic,
  ) async {
    if (!await root.exists()) {
      return const LocalArchiveSnapshot(
        state: LocalStorageState.missing,
        archiveExists: false,
        archiveBytes: 0,
        looseBytes: 0,
      );
    }
    final files = await _scanLooseFiles(
      root,
      comic,
      hashFiles: false,
      cancellationToken: LocalArchiveCancellationToken(),
      operation: LocalArchiveOperation.inspect,
    );
    final looseBytes = files.fold(0, (sum, file) => sum + file.size);
    final archive = _archiveFile(root);
    final archiveExists = await archive.exists();
    final archiveBytes = archiveExists ? await archive.length() : 0;
    if (!archiveExists) {
      return LocalArchiveSnapshot(
        state: files.isEmpty
            ? LocalStorageState.missing
            : LocalStorageState.loose,
        archiveExists: false,
        archiveBytes: 0,
        looseBytes: looseBytes,
      );
    }
    try {
      final pair = await _readValidPair(root, comic, throwOnInvalid: true);
      if (pair == null) {
        throw const LocalArchiveException('Archive manifest is missing');
      }
      final dirty = await _dirtyMarker(root).exists();
      if (files.isEmpty && !dirty) {
        return LocalArchiveSnapshot(
          state: LocalStorageState.archived,
          archiveExists: true,
          archiveBytes: archiveBytes,
          looseBytes: 0,
          manifest: pair.manifest,
        );
      }
      final fullMatch = _compareFilesQuick(
        files,
        pair.manifest,
        requireAll: true,
      );
      final cleanupMatch = await _markerMatches(
        _cleanupMarker(root),
        pair.manifest.identity,
      );
      final partialCleanup =
          cleanupMatch &&
          _compareFilesQuick(files, pair.manifest, requireAll: false);
      final expanded = !dirty && (fullMatch || partialCleanup);
      return LocalArchiveSnapshot(
        state: expanded ? LocalStorageState.expanded : LocalStorageState.dirty,
        archiveExists: true,
        archiveBytes: archiveBytes,
        looseBytes: looseBytes,
        manifest: pair.manifest,
      );
    } catch (error) {
      return LocalArchiveSnapshot(
        state: LocalStorageState.error,
        archiveExists: true,
        archiveBytes: archiveBytes,
        looseBytes: looseBytes,
        errorMessage: error.toString(),
      );
    }
  }

  Future<_ArchivePair?> _readValidPair(
    Directory root,
    LocalComic comic, {
    required bool throwOnInvalid,
  }) async {
    final archive = _archiveFile(root);
    final manifestFile = _manifestFile(root);
    final archiveExists = await archive.exists();
    final manifestExists = await manifestFile.exists();
    if (!archiveExists && !manifestExists) {
      return null;
    }
    try {
      if (!archiveExists || !manifestExists) {
        throw const LocalArchiveException('Incomplete archive metadata pair');
      }
      final manifest = await _readManifest(manifestFile);
      _validateManifestIdentity(manifest, comic);
      await _validateArchive(archive, manifest);
      return _ArchivePair(archive, manifestFile, manifest);
    } catch (_) {
      if (throwOnInvalid) rethrow;
      return null;
    }
  }

  void _validateManifestIdentity(ArchiveManifest manifest, LocalComic comic) {
    if (manifest.comicId != comic.id ||
        manifest.comicType != comic.comicType.value ||
        manifest.sourceKey != comic.sourceKey) {
      throw const LocalArchiveException('Archive belongs to a different comic');
    }
  }

  Future<ArchiveManifest> _readManifest(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString(encoding: utf8));
      if (decoded is! Map) {
        throw const FormatException('Archive manifest is not an object');
      }
      return ArchiveManifest.fromJson(Map<String, dynamic>.from(decoded));
    } on LocalArchiveException {
      rethrow;
    } catch (error) {
      throw LocalArchiveException('Invalid archive manifest: $error');
    }
  }

  Future<void> _validateArchive(
    File archive,
    ArchiveManifest manifest, {
    bool verifyContent = false,
    LocalArchiveCancellationToken? cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  }) async {
    ZipFile? zip;
    try {
      zip = ZipFile.openRead(archive.path);
      final entries = zip.getAllEntries();
      if (entries.length != manifest.entries.length) {
        throw const LocalArchiveException('Archive entry count does not match');
      }
      final expected = {
        for (final entry in manifest.entries) entry.path: entry,
      };
      final seen = <String>{};
      final seenCaseInsensitive = <String>{};
      for (final entry in entries) {
        cancellationToken?.throwIfCancelled();
        if (entry.isDir) {
          throw const LocalArchiveException(
            'Archive contains a directory entry',
          );
        }
        final path = normalizeLocalArchiveEntryPath(entry.name);
        if (!seen.add(path) || !seenCaseInsensitive.add(path.toLowerCase())) {
          throw LocalArchiveException('Duplicate archive entry: $path');
        }
        final manifestEntry = expected[path];
        if (manifestEntry == null || manifestEntry.size != entry.size) {
          throw LocalArchiveException(
            'Archive entry does not match manifest: $path',
          );
        }
      }
      if (verifyContent) {
        // Read and hash one entry at a time in an isolate. This keeps memory
        // bounded to roughly the largest page and avoids writing every
        // decompressed page to slow external storage solely for verification.
        zip.close();
        zip = null;
        final actualHashes = await _hashArchiveEntries(
          archive,
          manifest,
          cancellationToken ?? LocalArchiveCancellationToken(),
          onProgress,
        );
        cancellationToken?.throwIfCancelled();
        for (final manifestEntry in manifest.entries) {
          if (actualHashes[manifestEntry.path] != manifestEntry.sha256) {
            throw LocalArchiveException(
              'Archive entry checksum does not match manifest: '
              '${manifestEntry.path}',
            );
          }
        }
      }
    } on LocalArchiveException {
      rethrow;
    } catch (error) {
      throw LocalArchiveException('Invalid archive: $error');
    } finally {
      zip?.close();
    }
  }

  Future<Map<String, String>> _hashArchiveEntries(
    File archive,
    ArchiveManifest manifest,
    LocalArchiveCancellationToken cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  ) async {
    cancellationToken.throwIfCancelled();
    final receivePort = ReceivePort();
    final completion = Completer<Map<String, String>>();
    SendPort? controlPort;
    late final Isolate worker;
    late final StreamSubscription<Object?> subscription;
    worker = await Isolate.spawn<List<Object?>>(_hashArchiveWorker, [
      receivePort.sendPort,
      archive.path,
    ], onExit: receivePort.sendPort);
    subscription = receivePort.listen((message) {
      if (completion.isCompleted) return;
      if (message == null) {
        completion.completeError(
          const LocalArchiveException(
            'Compressed file verification worker stopped unexpectedly',
          ),
        );
        return;
      }
      if (message is! List || message.isEmpty) return;
      switch (message[0]) {
        case _archiveWorkerReady:
          controlPort = message[1] as SendPort;
          controlPort!.send(!cancellationToken.isCancelled);
          break;
        case _archiveWorkerProgress:
          onProgress?.call(
            LocalArchiveProgress(
              operation: LocalArchiveOperation.verify,
              completedFiles: message[1] as int,
              totalFiles: manifest.entries.length,
              currentPath: message[3] as String,
              completedBytes: message[2] as int,
              totalBytes: manifest.uncompressedBytes,
            ),
          );
          controlPort?.send(!cancellationToken.isCancelled);
          break;
        case _archiveWorkerDone:
          completion.complete(Map<String, String>.from(message[1] as Map));
          break;
        case _archiveWorkerError:
          completion.completeError(
            LocalArchiveException(message[1].toString()),
            StackTrace.fromString(message[2].toString()),
          );
          break;
        case _archiveWorkerCancelled:
          completion.completeError(const LocalArchiveCancelledException());
          break;
      }
    });
    unawaited(
      cancellationToken.whenCancelled.then((_) {
        controlPort?.send(false);
      }),
    );
    try {
      return await completion.future;
    } finally {
      worker.kill(priority: Isolate.immediate);
      await subscription.cancel();
      receivePort.close();
    }
  }

  Future<List<_LooseFile>> _scanLooseFiles(
    Directory root,
    LocalComic comic, {
    required bool hashFiles,
    required LocalArchiveCancellationToken cancellationToken,
    required LocalArchiveOperation operation,
    LocalArchiveProgressCallback? onProgress,
  }) async {
    final metadataPath = p.normalize(_metadataDirectory(root).path);
    final coverPath = _normalizedComparablePath(comic.coverFile.path);
    final paths = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      cancellationToken.throwIfCancelled();
      // Directory.list already resolves the entry kind. Re-statting every
      // entry can report notFound for otherwise readable files on some
      // Android external-storage providers, which made a populated comic look
      // empty and prevented compression from ever reaching the ZIP writer.
      if (entity is Link) {
        throw LocalArchiveException('Links are not supported: ${entity.path}');
      }
      final normalizedPath = p.normalize(entity.path);
      if (normalizedPath == metadataPath ||
          p.isWithin(metadataPath, normalizedPath)) {
        continue;
      }
      if (entity is! File ||
          _normalizedComparablePath(normalizedPath) == coverPath) {
        continue;
      }
      paths.add(entity);
    }
    paths.sort((a, b) => a.path.compareTo(b.path));
    final candidates = <({File file, FileStat stat})>[];
    for (final file in paths) {
      cancellationToken.throwIfCancelled();
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw LocalArchiveException(
          'Comic file changed during scan: ${file.path}',
        );
      }
      candidates.add((file: file, stat: stat));
    }
    final totalBytes = candidates.fold<int>(
      0,
      (sum, candidate) => sum + candidate.stat.size,
    );
    var completedBytes = 0;
    final result = <_LooseFile>[];
    for (var i = 0; i < candidates.length; i++) {
      cancellationToken.throwIfCancelled();
      final candidate = candidates[i];
      final file = candidate.file;
      final relative = p
          .relative(file.path, from: root.path)
          .replaceAll('\\', '/');
      final archivePath = normalizeLocalArchiveEntryPath(relative);
      final stat = candidate.stat;
      final hash = hashFiles ? await _hashFile(file, cancellationToken) : null;
      result.add(
        _LooseFile(
          file: file,
          archivePath: archivePath,
          size: stat.size,
          modifiedAtMillis: stat.modified.millisecondsSinceEpoch,
          sha256: hash,
        ),
      );
      completedBytes += stat.size;
      onProgress?.call(
        LocalArchiveProgress(
          operation: operation,
          completedFiles: i + 1,
          totalFiles: candidates.length,
          currentPath: archivePath,
          completedBytes: completedBytes,
          totalBytes: totalBytes,
        ),
      );
    }
    final duplicatePaths = <String>{};
    for (final file in result) {
      if (!duplicatePaths.add(file.archivePath.toLowerCase())) {
        throw LocalArchiveException(
          'Case-conflicting comic paths are not supported: ${file.archivePath}',
        );
      }
    }
    return result;
  }

  Future<String> _hashFile(
    File file,
    LocalArchiveCancellationToken cancellationToken,
  ) async {
    cancellationToken.throwIfCancelled();
    final digest = await sha256.bind(file.openRead()).first;
    cancellationToken.throwIfCancelled();
    return digest.toString();
  }

  Future<void> _writeZip(
    File output,
    List<_LooseFile> files,
    LocalArchiveCancellationToken cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  ) async {
    await output.deleteIgnoreError();
    cancellationToken.throwIfCancelled();
    final names = files.map((file) => file.archivePath).toList(growable: false);
    final sourceFiles = files
        .map((file) => file.file.path)
        .toList(growable: false);
    final sizes = files.map((file) => file.size).toList(growable: false);
    final totalBytes = sizes.fold<int>(0, (sum, size) => sum + size);
    // Use archive's streaming Dart IO writer instead of zip_flutter's native
    // writer. The latter can fail for an entire Android library when native
    // code cannot reopen app-readable source paths, and its async worker can
    // remain permanently busy after extraction on Windows. A dedicated
    // isolate keeps compression off the UI and reports each completed page.
    final receivePort = ReceivePort();
    final completion = Completer<void>();
    SendPort? controlPort;
    late final Isolate worker;
    late final StreamSubscription<Object?> subscription;
    worker = await Isolate.spawn<List<Object?>>(_writeZipWorker, [
      receivePort.sendPort,
      output.path,
      names,
      sourceFiles,
      sizes,
    ], onExit: receivePort.sendPort);
    subscription = receivePort.listen((message) {
      if (completion.isCompleted) return;
      if (message == null) {
        completion.completeError(
          const LocalArchiveException(
            'Compressed file worker stopped unexpectedly',
          ),
        );
        return;
      }
      if (message is! List || message.isEmpty) return;
      switch (message[0]) {
        case _archiveWorkerReady:
          controlPort = message[1] as SendPort;
          controlPort!.send(!cancellationToken.isCancelled);
          break;
        case _archiveWorkerProgress:
          final completedFiles = message[1] as int;
          onProgress?.call(
            LocalArchiveProgress(
              operation: LocalArchiveOperation.compress,
              completedFiles: completedFiles,
              totalFiles: files.length,
              currentPath: names[completedFiles - 1],
              completedBytes: message[2] as int,
              totalBytes: totalBytes,
            ),
          );
          controlPort?.send(!cancellationToken.isCancelled);
          break;
        case _archiveWorkerDone:
          completion.complete();
          break;
        case _archiveWorkerError:
          completion.completeError(
            LocalArchiveException(message[1].toString()),
            StackTrace.fromString(message[2].toString()),
          );
          break;
        case _archiveWorkerCancelled:
          completion.completeError(const LocalArchiveCancelledException());
          break;
      }
    });
    unawaited(
      cancellationToken.whenCancelled.then((_) {
        // Let the worker finish the current file and close all file handles.
        // Killing it in the middle of InputFileStream work can leave Windows
        // source files locked for the lifetime of the process.
        controlPort?.send(false);
      }),
    );
    try {
      await completion.future;
      cancellationToken.throwIfCancelled();
    } finally {
      worker.kill(priority: Isolate.immediate);
      await subscription.cancel();
      receivePort.close();
    }
  }

  Future<void> _restorePair(
    Directory root,
    LocalComic comic,
    _ArchivePair pair,
    LocalArchiveCancellationToken cancellationToken,
    LocalArchiveProgressCallback? onProgress, {
    required bool preserveExisting,
  }) async {
    cancellationToken.throwIfCancelled();
    await _validateArchive(pair.archive, pair.manifest);
    final staging = Directory(
      p.join(_metadataDirectory(root).path, 'restore-${const Uuid().v4()}'),
    );
    await staging.create(recursive: true);
    try {
      await _extractArchive(
        pair.archive,
        staging,
        pair.manifest,
        cancellationToken,
        onProgress,
      );
      cancellationToken.throwIfCancelled();
      final stagedFiles = await _scanExtractedFiles(staging, cancellationToken);
      if (!_compareExtractedFiles(stagedFiles, pair.manifest)) {
        throw const LocalArchiveException(
          'Extracted files do not match the archive manifest',
        );
      }
      final manifestByPath = {
        for (final entry in pair.manifest.entries) entry.path: entry,
      };
      var completedBytes = 0;
      for (var i = 0; i < stagedFiles.length; i++) {
        cancellationToken.throwIfCancelled();
        final staged = stagedFiles[i];
        final destinationPath = p.joinAll([
          root.path,
          ...staged.archivePath.split('/'),
        ]);
        if (!p.isWithin(root.path, destinationPath)) {
          throw const LocalArchiveException('Unsafe restore destination');
        }
        final destination = File(destinationPath);
        final manifestEntry = manifestByPath[staged.archivePath]!;
        if (await destination.exists()) {
          if (!preserveExisting) {
            throw LocalArchiveException(
              'Restore destination already exists: ${staged.archivePath}',
            );
          }
        } else {
          await destination.parent.create(recursive: true);
          await staged.file.rename(destination.path);
          try {
            await destination.setLastModified(
              DateTime.fromMillisecondsSinceEpoch(
                manifestEntry.modifiedAtMillis,
              ),
            );
          } catch (_) {
            // Some document providers do not support preserving timestamps. A
            // later compression still verifies content hashes before deletion.
          }
        }
        completedBytes += manifestEntry.size;
        onProgress?.call(
          LocalArchiveProgress(
            operation: LocalArchiveOperation.finalize,
            completedFiles: i + 1,
            totalFiles: stagedFiles.length,
            currentPath: staged.archivePath,
            completedBytes: completedBytes,
            totalBytes: pair.manifest.uncompressedBytes,
          ),
        );
      }
    } finally {
      await staging.deleteIgnoreError(recursive: true);
    }
  }

  Future<void> _extractArchive(
    File archive,
    Directory staging,
    ArchiveManifest manifest,
    LocalArchiveCancellationToken cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  ) async {
    cancellationToken.throwIfCancelled();
    final receivePort = ReceivePort();
    final completion = Completer<void>();
    SendPort? controlPort;
    late final Isolate worker;
    late final StreamSubscription<Object?> subscription;
    worker = await Isolate.spawn<List<Object?>>(_extractArchiveWorker, [
      receivePort.sendPort,
      archive.path,
      staging.path,
      {
        for (final entry in manifest.entries)
          entry.path: [entry.size, entry.sha256],
      },
    ], onExit: receivePort.sendPort);
    subscription = receivePort.listen((message) {
      if (completion.isCompleted) return;
      if (message == null) {
        completion.completeError(
          const LocalArchiveException(
            'Compressed comic opening worker stopped unexpectedly',
          ),
        );
        return;
      }
      if (message is! List || message.isEmpty) return;
      switch (message[0]) {
        case _archiveWorkerReady:
          controlPort = message[1] as SendPort;
          controlPort!.send(!cancellationToken.isCancelled);
          break;
        case _archiveWorkerProgress:
          onProgress?.call(
            LocalArchiveProgress(
              operation: LocalArchiveOperation.restore,
              completedFiles: message[1] as int,
              totalFiles: manifest.entries.length,
              currentPath: message[3] as String,
              completedBytes: message[2] as int,
              totalBytes: manifest.uncompressedBytes,
            ),
          );
          controlPort?.send(!cancellationToken.isCancelled);
          break;
        case _archiveWorkerDone:
          completion.complete();
          break;
        case _archiveWorkerError:
          completion.completeError(
            LocalArchiveException(message[1].toString()),
            StackTrace.fromString(message[2].toString()),
          );
          break;
        case _archiveWorkerCancelled:
          completion.completeError(const LocalArchiveCancelledException());
          break;
      }
    });
    unawaited(
      cancellationToken.whenCancelled.then((_) {
        controlPort?.send(false);
      }),
    );
    try {
      await completion.future;
      cancellationToken.throwIfCancelled();
    } finally {
      worker.kill(priority: Isolate.immediate);
      await subscription.cancel();
      receivePort.close();
    }
  }

  Future<List<_LooseFile>> _scanExtractedFiles(
    Directory root,
    LocalArchiveCancellationToken cancellationToken,
  ) async {
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      cancellationToken.throwIfCancelled();
      if (entity is Link) {
        throw const LocalArchiveException('Extracted archive contains a link');
      }
      if (entity is File) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final result = <_LooseFile>[];
    for (var i = 0; i < files.length; i++) {
      cancellationToken.throwIfCancelled();
      final file = files[i];
      final path = normalizeLocalArchiveEntryPath(
        p.relative(file.path, from: root.path).replaceAll('\\', '/'),
      );
      final stat = await file.stat();
      result.add(
        _LooseFile(
          file: file,
          archivePath: path,
          size: stat.size,
          modifiedAtMillis: stat.modified.millisecondsSinceEpoch,
          // Extraction verifies each entry before writing it to staging.
          sha256: null,
        ),
      );
    }
    return result;
  }

  bool _compareExtractedFiles(
    List<_LooseFile> files,
    ArchiveManifest manifest,
  ) {
    if (files.length != manifest.entries.length) return false;
    final expected = {for (final entry in manifest.entries) entry.path: entry};
    for (final file in files) {
      final entry = expected[file.archivePath];
      if (entry == null || entry.size != file.size) return false;
    }
    return true;
  }

  Future<void> _deleteVerifiedLooseFiles(
    Directory root,
    LocalComic comic,
    List<_LooseFile> files,
    ArchiveManifest manifest,
    LocalArchiveCancellationToken cancellationToken,
    LocalArchiveProgressCallback? onProgress,
  ) async {
    final byPath = {for (final entry in manifest.entries) entry.path: entry};
    for (var i = 0; i < files.length; i++) {
      cancellationToken.throwIfCancelled();
      if (await _dirtyMarker(root).exists()) {
        throw const LocalArchiveException(
          'Comic was marked dirty during archive cleanup',
        );
      }
      final file = files[i];
      final expected = byPath[file.archivePath];
      if (expected == null || !await file.file.exists()) {
        continue;
      }
      final stat = await file.file.stat();
      // Content was already checked against the manifest before and after ZIP
      // creation. Re-check metadata at the deletion boundary so a normal
      // concurrent edit is never removed, without reading every page yet
      // another time.
      if (stat.size != expected.size ||
          stat.modified.millisecondsSinceEpoch != expected.modifiedAtMillis) {
        throw LocalArchiveException(
          'Comic file changed before cleanup: ${file.archivePath}',
        );
      }
      await file.file.delete();
      onProgress?.call(
        LocalArchiveProgress(
          operation: LocalArchiveOperation.cleanup,
          completedFiles: i + 1,
          totalFiles: files.length,
          currentPath: file.archivePath,
        ),
      );
    }
    await _deleteEmptyContentDirectories(root, comic);
  }

  Future<void> _deleteEmptyContentDirectories(
    Directory root,
    LocalComic comic,
  ) async {
    final directories = <Directory>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Directory &&
          p.normalize(entity.path) !=
              p.normalize(_metadataDirectory(root).path)) {
        directories.add(entity);
      }
    }
    directories.sort((a, b) => b.path.length.compareTo(a.path.length));
    final coverParent = p.normalize(comic.coverFile.parent.path);
    for (final directory in directories) {
      if (p.normalize(directory.path) == coverParent ||
          p.isWithin(directory.path, coverParent)) {
        continue;
      }
      try {
        if (await directory.list().isEmpty) {
          await directory.delete();
        }
      } catch (_) {
        // A non-empty or concurrently changed directory is intentionally kept.
      }
    }
  }

  bool _compareFiles(
    List<_LooseFile> files,
    ArchiveManifest manifest, {
    required bool requireAll,
  }) {
    if (requireAll && files.length != manifest.entries.length) return false;
    final expected = {for (final entry in manifest.entries) entry.path: entry};
    for (final file in files) {
      final entry = expected[file.archivePath];
      if (entry == null ||
          entry.size != file.size ||
          file.sha256 == null ||
          entry.sha256 != file.sha256) {
        return false;
      }
    }
    return true;
  }

  bool _compareFilesQuick(
    List<_LooseFile> files,
    ArchiveManifest manifest, {
    required bool requireAll,
  }) {
    if (requireAll && files.length != manifest.entries.length) return false;
    final expected = {for (final entry in manifest.entries) entry.path: entry};
    for (final file in files) {
      final entry = expected[file.archivePath];
      if (entry == null ||
          entry.size != file.size ||
          entry.modifiedAtMillis != file.modifiedAtMillis) {
        return false;
      }
    }
    return true;
  }

  bool _sameFileMetadata(List<_LooseFile> before, List<_LooseFile> after) {
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      final a = before[i];
      final b = after[i];
      if (a.archivePath != b.archivePath ||
          a.size != b.size ||
          a.modifiedAtMillis != b.modifiedAtMillis) {
        return false;
      }
    }
    return true;
  }

  Future<void> _commitPair(
    Directory root,
    LocalComic comic,
    File archiveTemp,
    File manifestTemp,
    ArchiveManifest manifest,
  ) async {
    final archive = _archiveFile(root);
    final manifestFile = _manifestFile(root);
    final archiveBackup = _archiveBackup(root);
    final manifestBackup = _manifestBackup(root);
    await archiveBackup.deleteIgnoreError();
    await manifestBackup.deleteIgnoreError();
    var archiveBackedUp = false;
    var manifestBackedUp = false;
    try {
      if (await archive.exists()) {
        await archive.rename(archiveBackup.path);
        archiveBackedUp = true;
      }
      if (await manifestFile.exists()) {
        await manifestFile.rename(manifestBackup.path);
        manifestBackedUp = true;
      }
      await archiveTemp.rename(archive.path);
      await manifestTemp.rename(manifestFile.path);
      _validateManifestIdentity(manifest, comic);
      await _validateArchive(archive, manifest);
      await archiveBackup.deleteIgnoreError();
      await manifestBackup.deleteIgnoreError();
    } catch (error, stackTrace) {
      await archive.deleteIgnoreError();
      await manifestFile.deleteIgnoreError();
      if (archiveBackedUp && await archiveBackup.exists()) {
        await archiveBackup.rename(archive.path);
      }
      if (manifestBackedUp && await manifestBackup.exists()) {
        await manifestBackup.rename(manifestFile.path);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _recoverInterruptedCommit(
    Directory root,
    LocalComic comic,
  ) async {
    final archive = _archiveFile(root);
    final manifest = _manifestFile(root);
    final archiveBackup = _archiveBackup(root);
    final manifestBackup = _manifestBackup(root);
    final finalValid = await _pairIsValid(archive, manifest, comic);
    if (finalValid) {
      await archiveBackup.deleteIgnoreError();
      await manifestBackup.deleteIgnoreError();
      return;
    }
    if (await _recoverFinalArchiveFromTemporaryManifest(root, comic)) {
      await archiveBackup.deleteIgnoreError();
      await manifestBackup.deleteIgnoreError();
      return;
    }
    final backupValid = await _pairIsValid(
      archiveBackup,
      manifestBackup,
      comic,
    );
    if (!backupValid) return;
    await archive.deleteIgnoreError();
    await manifest.deleteIgnoreError();
    await archiveBackup.rename(archive.path);
    await manifestBackup.rename(manifest.path);
  }

  Future<bool> _recoverFinalArchiveFromTemporaryManifest(
    Directory root,
    LocalComic comic,
  ) async {
    final archive = _archiveFile(root);
    final manifest = _manifestFile(root);
    final metadata = _metadataDirectory(root);
    if (!await archive.exists() || !await metadata.exists()) return false;
    await for (final entity in metadata.list(followLinks: false)) {
      if (entity is! File ||
          !p.basename(entity.path).startsWith('$manifestFileName.tmp-')) {
        continue;
      }
      try {
        final candidate = await _readManifest(entity);
        _validateManifestIdentity(candidate, comic);
        // This path is only used after an interrupted first commit. Pay the
        // one-time content hash cost before accepting the temporary manifest
        // as the durable companion of the only archive copy.
        await _validateArchive(archive, candidate, verifyContent: true);
        await manifest.deleteIgnoreError();
        await entity.rename(manifest.path);
        return true;
      } catch (_) {
        // Keep searching. Invalid candidates remain untouched until normal
        // stale-operation cleanup, and the archive itself is never deleted.
      }
    }
    return false;
  }

  Future<bool> _pairIsValid(
    File archive,
    File manifestFile,
    LocalComic comic,
  ) async {
    if (!await archive.exists() || !await manifestFile.exists()) return false;
    try {
      final manifest = await _readManifest(manifestFile);
      _validateManifestIdentity(manifest, comic);
      await _validateArchive(archive, manifest);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeStaleOperationFiles(Directory root) async {
    final metadata = _metadataDirectory(root);
    if (!await metadata.exists()) return;
    await for (final entity in metadata.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is File &&
          (name.startsWith('$archiveFileName.tmp-') ||
              name.startsWith('$manifestFileName.tmp-'))) {
        await entity.deleteIgnoreError();
      } else if (entity is Directory &&
          (name.startsWith('restore-') ||
              name.startsWith('$archiveFileName.verify-'))) {
        await entity.deleteIgnoreError(recursive: true);
      }
    }
  }

  Future<void> _writeMarker(File file, String archiveIdentity) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'archive': archiveIdentity,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }),
      encoding: utf8,
      flush: true,
    );
    await file.deleteIgnoreError();
    await temp.rename(file.path);
  }

  Future<void> _markDirtyRoot(Directory root) async {
    final metadata = _metadataDirectory(root);
    await metadata.create(recursive: true);
    final marker = _dirtyMarker(root);
    final temp = File('${marker.path}.tmp');
    await temp.writeAsString(
      DateTime.now().millisecondsSinceEpoch.toString(),
      encoding: utf8,
      flush: true,
    );
    await marker.deleteIgnoreError();
    await temp.rename(marker.path);
  }

  Future<bool> _markerMatches(File file, String identity) async {
    if (!await file.exists()) return false;
    try {
      final value = jsonDecode(await file.readAsString(encoding: utf8));
      return value is Map && value['archive'] == identity;
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearStateMarkers(Directory root) async {
    await _expandedMarker(root).deleteIgnoreError();
    await _dirtyMarker(root).deleteIgnoreError();
    await _cleanupMarker(root).deleteIgnoreError();
  }

  String _normalizedComparablePath(String value) {
    final normalized = p.normalize(p.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  LocalArchiveResult _resultFromSnapshot(
    LocalArchiveSnapshot snapshot, {
    required bool rebuiltArchive,
  }) {
    return LocalArchiveResult(
      state: snapshot.state,
      archiveExists: snapshot.archiveExists,
      archiveBytes: snapshot.archiveBytes,
      looseBytes: snapshot.looseBytes,
      manifest: snapshot.manifest,
      errorMessage: snapshot.errorMessage,
      rebuiltArchive: rebuiltArchive,
    );
  }
}

void _hashArchiveWorker(List<Object?> request) async {
  final sendPort = request[0] as SendPort;
  final archivePath = request[1] as String;
  final controlPort = ReceivePort();
  final control = StreamIterator<Object?>(controlPort);
  sendPort.send([_archiveWorkerReady, controlPort.sendPort]);
  ZipFile? zip;
  final hashes = <String, String>{};
  Object? pendingError;
  StackTrace? pendingStackTrace;
  try {
    if (!await control.moveNext() || control.current != true) {
      throw const LocalArchiveCancelledException();
    }
    zip = ZipFile.openRead(archivePath);
    final caseInsensitivePaths = <String>{};
    final entries = zip.getAllEntries();
    var completedBytes = 0;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (entry.isDir) {
        throw const LocalArchiveException('Archive contains a directory entry');
      }
      final path = normalizeLocalArchiveEntryPath(entry.name);
      if (!caseInsensitivePaths.add(path.toLowerCase())) {
        throw LocalArchiveException('Duplicate archive entry: $path');
      }
      final bytes = entry.read();
      hashes[path] = sha256.convert(bytes).toString();
      completedBytes += entry.size;
      sendPort.send([_archiveWorkerProgress, index + 1, completedBytes, path]);
      if (!await control.moveNext() || control.current != true) {
        throw const LocalArchiveCancelledException();
      }
    }
  } catch (error, stackTrace) {
    pendingError = error;
    pendingStackTrace = stackTrace;
  } finally {
    zip?.close();
    await control.cancel();
    controlPort.close();
  }
  if (pendingError is LocalArchiveCancelledException) {
    sendPort.send(const [_archiveWorkerCancelled]);
  } else if (pendingError != null) {
    sendPort.send([
      _archiveWorkerError,
      pendingError.toString(),
      pendingStackTrace.toString(),
    ]);
  } else {
    sendPort.send([_archiveWorkerDone, hashes]);
  }
}

void _extractArchiveWorker(List<Object?> request) async {
  final sendPort = request[0] as SendPort;
  final archivePath = request[1] as String;
  final stagingPath = p.normalize(p.absolute(request[2] as String));
  final expected = Map<String, Object?>.from(request[3] as Map);
  final controlPort = ReceivePort();
  final control = StreamIterator<Object?>(controlPort);
  sendPort.send([_archiveWorkerReady, controlPort.sendPort]);
  ZipFile? zip;
  Object? pendingError;
  StackTrace? pendingStackTrace;
  try {
    if (!await control.moveNext() || control.current != true) {
      throw const LocalArchiveCancelledException();
    }
    zip = ZipFile.openRead(archivePath);
    final entries = zip.getAllEntries();
    if (entries.length != expected.length) {
      throw const LocalArchiveException('Archive entry count does not match');
    }
    final seen = <String>{};
    var completedBytes = 0;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (entry.isDir) {
        throw const LocalArchiveException('Archive contains a directory entry');
      }
      final path = normalizeLocalArchiveEntryPath(entry.name);
      if (!seen.add(path.toLowerCase())) {
        throw LocalArchiveException('Duplicate archive entry: $path');
      }
      final expectedValue = expected[path];
      if (expectedValue is! List || expectedValue.length != 2) {
        throw LocalArchiveException('Unexpected archive entry: $path');
      }
      final expectedSize = expectedValue[0] as int;
      final expectedHash = expectedValue[1] as String;
      final bytes = entry.read();
      if (bytes.length != expectedSize ||
          sha256.convert(bytes).toString() != expectedHash) {
        throw LocalArchiveException(
          'Archive entry checksum does not match manifest: $path',
        );
      }
      final destination = p.normalize(
        p.absolute(p.joinAll([stagingPath, ...path.split('/')])),
      );
      if (!p.isWithin(stagingPath, destination)) {
        throw const LocalArchiveException('Unsafe restore destination');
      }
      final output = File(destination);
      output.parent.createSync(recursive: true);
      output.writeAsBytesSync(bytes);
      completedBytes += expectedSize;
      sendPort.send([_archiveWorkerProgress, index + 1, completedBytes, path]);
      if (!await control.moveNext() || control.current != true) {
        throw const LocalArchiveCancelledException();
      }
    }
  } catch (error, stackTrace) {
    pendingError = error;
    pendingStackTrace = stackTrace;
  } finally {
    zip?.close();
    await control.cancel();
    controlPort.close();
  }
  if (pendingError is LocalArchiveCancelledException) {
    sendPort.send(const [_archiveWorkerCancelled]);
  } else if (pendingError != null) {
    sendPort.send([
      _archiveWorkerError,
      pendingError.toString(),
      pendingStackTrace.toString(),
    ]);
  } else {
    sendPort.send(const [_archiveWorkerDone]);
  }
}

const int _archiveWorkerProgress = 0;
const int _archiveWorkerDone = 1;
const int _archiveWorkerError = 2;
const int _archiveWorkerReady = 3;
const int _archiveWorkerCancelled = 4;

void _writeZipWorker(List<Object?> request) async {
  final sendPort = request[0] as SendPort;
  final outputPath = request[1] as String;
  final names = (request[2] as List).cast<String>();
  final sourceFiles = (request[3] as List).cast<String>();
  final sizes = (request[4] as List).cast<int>();
  final controlPort = ReceivePort();
  final control = StreamIterator<Object?>(controlPort);
  sendPort.send([_archiveWorkerReady, controlPort.sendPort]);
  final encoder = archive_io.ZipFileEncoder();
  var completedBytes = 0;
  var opened = false;
  Object? pendingError;
  StackTrace? pendingStackTrace;
  try {
    if (names.length != sourceFiles.length || names.length != sizes.length) {
      throw const LocalArchiveException('Archive input list length mismatch');
    }
    if (!await control.moveNext() || control.current != true) {
      throw const LocalArchiveCancelledException();
    }
    encoder.create(outputPath, level: 1);
    opened = true;
    for (var index = 0; index < names.length; index++) {
      encoder.addFileSync(File(sourceFiles[index]), names[index], 1);
      completedBytes += sizes[index];
      sendPort.send([_archiveWorkerProgress, index + 1, completedBytes]);
      if (!await control.moveNext() || control.current != true) {
        throw const LocalArchiveCancelledException();
      }
    }
  } catch (error, stackTrace) {
    pendingError = error;
    pendingStackTrace = stackTrace;
  }
  if (opened) {
    try {
      encoder.closeSync();
    } catch (error, stackTrace) {
      pendingError ??= error;
      pendingStackTrace ??= stackTrace;
    }
  }
  await control.cancel();
  controlPort.close();
  if (pendingError is LocalArchiveCancelledException) {
    sendPort.send(const [_archiveWorkerCancelled]);
  } else if (pendingError != null) {
    sendPort.send([
      _archiveWorkerError,
      pendingError.toString(),
      pendingStackTrace.toString(),
    ]);
  } else {
    sendPort.send(const [_archiveWorkerDone]);
  }
}

class _ArchivePair {
  const _ArchivePair(this.archive, this.manifestFile, this.manifest);

  final File archive;
  final File manifestFile;
  final ArchiveManifest manifest;
}

class _ActiveWriterState {
  int count = 0;
  final Completer<void> idle = Completer<void>();
}

class _LooseFile {
  const _LooseFile({
    required this.file,
    required this.archivePath,
    required this.size,
    required this.modifiedAtMillis,
    required this.sha256,
  });

  final File file;
  final String archivePath;
  final int size;
  final int modifiedAtMillis;
  final String? sha256;

  ArchiveManifestEntry toManifestEntry() {
    final hash = sha256;
    if (hash == null) {
      throw const LocalArchiveException('Missing content hash');
    }
    return ArchiveManifestEntry(
      path: archivePath,
      size: size,
      modifiedAtMillis: modifiedAtMillis,
      sha256: hash,
    );
  }
}

int _readInt(Object? value, {required String field}) {
  final parsed = switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text),
    _ => null,
  };
  if (parsed == null) {
    throw FormatException('Invalid $field');
  }
  return parsed;
}

int _readNonNegativeInt(Object? value, {required String field}) {
  final parsed = _readInt(value, field: field);
  if (parsed < 0) {
    throw FormatException('Invalid $field');
  }
  return parsed;
}
