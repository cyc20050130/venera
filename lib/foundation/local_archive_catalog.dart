import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/local_archive.dart';

/// Lightweight archive state catalog for library/list rendering.
///
/// It only reads file metadata, the manifest, and tiny state markers. ZIP
/// enumeration and loose-page scans remain in [LocalArchiveService] and run
/// when opening, compressing, or explicitly reconciling a comic.
final class LocalArchiveCatalog {
  LocalArchiveCatalog._();

  static final LocalArchiveCatalog _instance = LocalArchiveCatalog._();

  factory LocalArchiveCatalog() => _instance;

  @visibleForTesting
  factory LocalArchiveCatalog.forTesting() => LocalArchiveCatalog._();

  static const int _maxManifestBytes = 64 * 1024 * 1024;

  final Map<String, _CatalogEntry> _entries = <String, _CatalogEntry>{};

  Future<LocalArchiveSnapshot> inspectFast(
    LocalComic comic, {
    bool force = false,
  }) async {
    final paths = _ArchivePaths(comic.baseDir);
    final fingerprint = await _CatalogFingerprint.read(paths);
    final key = _key(comic);
    final cached = _entries[key];
    if (!force && cached != null && cached.fingerprint == fingerprint) {
      return cached.snapshot;
    }

    final snapshot = await _buildSnapshot(comic, paths, fingerprint);
    _entries[key] = _CatalogEntry(fingerprint, snapshot);
    return snapshot;
  }

  /// Runs the authoritative inspection and remembers its result. Callers use
  /// this for explicit repair/detail flows, never while lazily building a list.
  Future<LocalArchiveSnapshot> inspectDeep(
    LocalComic comic, {
    LocalArchiveService? service,
  }) async {
    final snapshot = await (service ?? LocalArchiveService()).inspect(comic);
    final paths = _ArchivePaths(comic.baseDir);
    _entries[_key(comic)] = _CatalogEntry(
      await _CatalogFingerprint.read(paths),
      snapshot,
    );
    return snapshot;
  }

  Future<void> remember(LocalComic comic, LocalArchiveSnapshot snapshot) async {
    final paths = _ArchivePaths(comic.baseDir);
    _entries[_key(comic)] = _CatalogEntry(
      await _CatalogFingerprint.read(paths),
      snapshot,
    );
  }

  void invalidate(LocalComic comic) => _entries.remove(_key(comic));

  void retainComics(Iterable<LocalComic> comics) {
    final retained = comics.map(_key).toSet();
    _entries.removeWhere((key, _) => !retained.contains(key));
  }

  @visibleForTesting
  int get cachedEntryCount => _entries.length;

  String _key(LocalComic comic) =>
      '${comic.comicType.value}\u0000${comic.sourceKey}\u0000${comic.id}\u0000${p.normalize(comic.baseDir)}';

  Future<LocalArchiveSnapshot> _buildSnapshot(
    LocalComic comic,
    _ArchivePaths paths,
    _CatalogFingerprint fingerprint,
  ) async {
    if (!fingerprint.root.exists) {
      return const LocalArchiveSnapshot(
        state: LocalStorageState.missing,
        archiveExists: false,
        archiveBytes: 0,
        looseBytes: 0,
      );
    }

    final archiveExists = fingerprint.archive.exists;
    final manifestExists = fingerprint.manifest.exists;
    if (!archiveExists && !manifestExists) {
      return const LocalArchiveSnapshot(
        state: LocalStorageState.loose,
        archiveExists: false,
        archiveBytes: 0,
        looseBytes: 0,
      );
    }
    if (!archiveExists || !manifestExists) {
      return LocalArchiveSnapshot(
        state: LocalStorageState.error,
        archiveExists: archiveExists,
        archiveBytes: fingerprint.archive.size,
        looseBytes: 0,
        errorMessage: 'Incomplete archive metadata pair',
      );
    }

    try {
      if (fingerprint.archive.size <= 0) {
        throw const FormatException('Compressed file is empty');
      }
      if (fingerprint.manifest.size <= 0 ||
          fingerprint.manifest.size > _maxManifestBytes) {
        throw const FormatException('Invalid archive manifest size');
      }
      final value = jsonDecode(
        await File(paths.manifest).readAsString(encoding: utf8),
      );
      if (value is! Map) {
        throw const FormatException('Archive manifest is not an object');
      }
      final manifest = ArchiveManifest.fromJson(
        Map<String, dynamic>.from(value),
      );
      if (manifest.comicId != comic.id ||
          manifest.comicType != comic.comicType.value ||
          manifest.sourceKey != comic.sourceKey) {
        throw const FormatException('Archive belongs to a different comic');
      }

      final state = fingerprint.dirty.exists
          ? LocalStorageState.dirty
          : await _markerMatches(paths.expanded, manifest.identity)
          ? LocalStorageState.expanded
          : LocalStorageState.archived;
      return LocalArchiveSnapshot(
        state: state,
        archiveExists: true,
        archiveBytes: fingerprint.archive.size,
        looseBytes: state == LocalStorageState.archived
            ? 0
            : manifest.uncompressedBytes,
        manifest: manifest,
      );
    } catch (error) {
      return LocalArchiveSnapshot(
        state: LocalStorageState.error,
        archiveExists: true,
        archiveBytes: fingerprint.archive.size,
        looseBytes: 0,
        errorMessage: error.toString(),
      );
    }
  }

  Future<bool> _markerMatches(String path, String identity) async {
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      final value = jsonDecode(await file.readAsString(encoding: utf8));
      return value is Map && value['archive'] == identity;
    } catch (_) {
      return false;
    }
  }
}

final class _ArchivePaths {
  _ArchivePaths(String root)
    : root = p.normalize(root),
      archive = p.join(
        root,
        LocalArchiveService.metadataDirectoryName,
        LocalArchiveService.archiveFileName,
      ),
      manifest = p.join(
        root,
        LocalArchiveService.metadataDirectoryName,
        LocalArchiveService.manifestFileName,
      ),
      expanded = p.join(
        root,
        LocalArchiveService.metadataDirectoryName,
        'expanded.json',
      ),
      dirty = p.join(root, LocalArchiveService.metadataDirectoryName, 'dirty'),
      cleanup = p.join(
        root,
        LocalArchiveService.metadataDirectoryName,
        'cleanup.json',
      );

  final String root;
  final String archive;
  final String manifest;
  final String expanded;
  final String dirty;
  final String cleanup;
}

@immutable
final class _FileStamp {
  const _FileStamp({
    required this.exists,
    required this.size,
    required this.modifiedMillis,
  });

  const _FileStamp.missing() : exists = false, size = 0, modifiedMillis = 0;

  final bool exists;
  final int size;
  final int modifiedMillis;

  static Future<_FileStamp> read(String path) async {
    try {
      final stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.notFound) {
        return const _FileStamp.missing();
      }
      return _FileStamp(
        exists: true,
        size: stat.size,
        modifiedMillis: stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return const _FileStamp.missing();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _FileStamp &&
      other.exists == exists &&
      other.size == size &&
      other.modifiedMillis == modifiedMillis;

  @override
  int get hashCode => Object.hash(exists, size, modifiedMillis);
}

@immutable
final class _CatalogFingerprint {
  const _CatalogFingerprint({
    required this.root,
    required this.archive,
    required this.manifest,
    required this.expanded,
    required this.dirty,
    required this.cleanup,
  });

  final _FileStamp root;
  final _FileStamp archive;
  final _FileStamp manifest;
  final _FileStamp expanded;
  final _FileStamp dirty;
  final _FileStamp cleanup;

  static Future<_CatalogFingerprint> read(_ArchivePaths paths) async {
    final stamps = await Future.wait(<Future<_FileStamp>>[
      _FileStamp.read(paths.root),
      _FileStamp.read(paths.archive),
      _FileStamp.read(paths.manifest),
      _FileStamp.read(paths.expanded),
      _FileStamp.read(paths.dirty),
      _FileStamp.read(paths.cleanup),
    ]);
    return _CatalogFingerprint(
      root: stamps[0],
      archive: stamps[1],
      manifest: stamps[2],
      expanded: stamps[3],
      dirty: stamps[4],
      cleanup: stamps[5],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _CatalogFingerprint &&
      other.root == root &&
      other.archive == archive &&
      other.manifest == manifest &&
      other.expanded == expanded &&
      other.dirty == dirty &&
      other.cleanup == cleanup;

  @override
  int get hashCode =>
      Object.hash(root, archive, manifest, expanded, dirty, cleanup);
}

final class _CatalogEntry {
  const _CatalogEntry(this.fingerprint, this.snapshot);

  final _CatalogFingerprint fingerprint;
  final LocalArchiveSnapshot snapshot;
}
