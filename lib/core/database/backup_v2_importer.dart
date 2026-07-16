import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:venera/core/database/app_database.dart';
import 'package:venera/core/domain/comic_key.dart';
import 'package:venera/utils/backup_v2.dart';

enum ImportedArchiveStatus { available, missing, relinked }

final class ImportedArchiveLink {
  const ImportedArchiveLink({
    required this.identityKey,
    required this.comicId,
    required this.comicType,
    required this.directory,
    required this.originalRoot,
    required this.relativePath,
    required this.originalPath,
    required this.expectedLength,
    required this.resolvedPath,
    required this.status,
    required this.updatedAtMillis,
  });

  final String identityKey;
  final String comicId;
  final String comicType;
  final String directory;
  final String? originalRoot;
  final String? relativePath;
  final String? originalPath;
  final int? expectedLength;
  final String? resolvedPath;
  final ImportedArchiveStatus status;
  final int updatedAtMillis;

  static ImportedArchiveLink fromRow(Map<Object?, Object?> row) {
    return ImportedArchiveLink(
      identityKey: row['identity_key'] as String,
      comicId: row['comic_id'] as String,
      comicType: row['comic_type'] as String,
      directory: row['directory'] as String,
      originalRoot: row['original_root'] as String?,
      relativePath: row['relative_path'] as String?,
      originalPath: row['original_path'] as String?,
      expectedLength: row['expected_length'] as int?,
      resolvedPath: row['resolved_path'] as String?,
      status: ImportedArchiveStatus.values.byName(row['status'] as String),
      updatedAtMillis: row['updated_at'] as int,
    );
  }
}

final class BackupV2ImportResult {
  const BackupV2ImportResult({
    required this.historyCount,
    required this.favoriteCollectionCount,
    required this.localComicCount,
    required this.sourceCount,
    required this.availableArchiveCount,
    required this.missingArchiveCount,
  });

  final int historyCount;
  final int favoriteCollectionCount;
  final int localComicCount;
  final int sourceCount;
  final int availableArchiveCount;
  final int missingArchiveCount;
}

/// Imports a validated, database-independent Backup V2 snapshot into the
/// rewrite database.
///
/// Parsing and archive-link probing finish before the write transaction starts.
/// A malformed backup therefore cannot partially replace existing user data.
/// ZIP files are never copied, moved or deleted: the importer only records a
/// verified location, or a durable `missing` entry that can be relinked later.
final class BackupV2Importer {
  BackupV2Importer(this.database, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase database;
  final DateTime Function() _clock;

  Future<BackupV2ImportResult> importDirectory(
    Directory directory, {
    String? localRoot,
  }) async {
    final manifest = validateExtractedBackupV2(directory);
    if (manifest == null) {
      throw const FormatException(
        'Legacy backups must use the compatibility importer',
      );
    }

    final payloads = <String, Uint8List>{};
    final entriesByPath = <String, BackupEntryV2>{};
    for (final entry in manifest.entries) {
      if (entriesByPath[entry.path] != null) {
        throw FormatException('Duplicate backup manifest path: ${entry.path}');
      }
      entriesByPath[entry.path] = entry;
      payloads[entry.path] = File(
        p.joinAll([directory.path, ...entry.path.split('/')]),
      ).readAsBytesSync();
    }

    final projection = _BackupProjection.parse(
      payloads: payloads,
      entriesByPath: entriesByPath,
    );
    final previousLinks = await archiveLinks();
    final previousRelinks = <String, String>{
      for (final link in previousLinks)
        if (link.status == ImportedArchiveStatus.relinked &&
            link.resolvedPath != null)
          link.identityKey: link.resolvedPath!,
    };
    final importedAt = _clock().toUtc().millisecondsSinceEpoch;
    final archiveLinksToWrite = <_ArchiveLinkProjection>[];
    for (final comic in projection.localComics) {
      archiveLinksToWrite.add(
        _buildArchiveLink(
          comic,
          importedRootOverride: localRoot,
          previousRelink: previousRelinks[comic.identityKey],
          updatedAt: importedAt,
        ),
      );
    }

    await database.raw.writeTransaction((tx) async {
      await tx.execute('DELETE FROM backup_import');
      await tx.execute('DELETE FROM backup_payloads');
      await tx.execute('DELETE FROM app_state');
      await tx.execute('DELETE FROM reading_history');
      await tx.execute('DELETE FROM favorite_collections');
      await tx.execute('DELETE FROM local_comics');
      await tx.execute('DELETE FROM local_archive_links');
      await tx.execute('DELETE FROM source_documents');

      if (manifest.entries.isNotEmpty) {
        await tx.executeBatch(
          '''
          INSERT INTO backup_payloads(path, kind, content, sha256, length)
          VALUES (?, ?, ?, ?, ?)
          ''',
          manifest.entries
              .map(
                (entry) => <Object?>[
                  entry.path,
                  entry.kind,
                  payloads[entry.path],
                  entry.sha256,
                  entry.length,
                ],
              )
              .toList(growable: false),
        );
      }
      if (projection.appState.isNotEmpty) {
        await tx.executeBatch(
          'INSERT INTO app_state(section_key, payload_json) VALUES (?, ?)',
          projection.appState.entries
              .map((entry) => <Object?>[entry.key, jsonEncode(entry.value)])
              .toList(growable: false),
        );
      }
      if (projection.history.isNotEmpty) {
        await tx.executeBatch(
          '''
          INSERT INTO reading_history(
            identity_key, source_key, comic_id, payload_json
          ) VALUES (?, ?, ?, ?)
          ''',
          projection.history
              .map(
                (entry) => <Object?>[
                  entry.identityKey,
                  entry.sourceKey,
                  entry.comicId,
                  entry.payloadJson,
                ],
              )
              .toList(growable: false),
        );
      }
      if (projection.favorites.isNotEmpty) {
        await tx.executeBatch(
          '''
          INSERT INTO favorite_collections(collection_name, payload_json)
          VALUES (?, ?)
          ''',
          projection.favorites.entries
              .map((entry) => <Object?>[entry.key, jsonEncode(entry.value)])
              .toList(growable: false),
        );
      }
      if (projection.localComics.isNotEmpty) {
        await tx.executeBatch(
          '''
          INSERT INTO local_comics(
            identity_key, comic_id, comic_type, directory, payload_json
          ) VALUES (?, ?, ?, ?, ?)
          ''',
          projection.localComics
              .map(
                (entry) => <Object?>[
                  entry.identityKey,
                  entry.comicId,
                  entry.comicType,
                  entry.directory,
                  entry.payloadJson,
                ],
              )
              .toList(growable: false),
        );
        await tx.executeBatch(
          '''
          INSERT INTO local_archive_links(
            identity_key, comic_id, comic_type, directory, original_root,
            relative_path, original_path, expected_length, resolved_path,
            status, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          archiveLinksToWrite
              .map((entry) => entry.parameters)
              .toList(growable: false),
        );
      }
      if (projection.sources.isNotEmpty) {
        await tx.executeBatch(
          '''
          INSERT INTO source_documents(
            name, content, sha256, expected_length, available
          ) VALUES (?, ?, ?, ?, ?)
          ''',
          projection.sources
              .map(
                (entry) => <Object?>[
                  entry.name,
                  entry.content,
                  entry.sha256,
                  entry.length,
                  entry.content == null ? 0 : 1,
                ],
              )
              .toList(growable: false),
        );
      }
      await tx.execute(
        '''
        INSERT INTO backup_import(
          singleton, format_version, app_version, created_at, imported_at
        ) VALUES (1, ?, ?, ?, ?)
        ''',
        [
          currentBackupFormatVersion,
          manifest.appVersion,
          manifest.createdAt.toUtc().toIso8601String(),
          importedAt,
        ],
      );
      await tx.execute(
        '''
        INSERT INTO app_metadata(key, value, updated_at) VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
          value = excluded.value,
          updated_at = excluded.updated_at
        ''',
        [
          'last_backup_import',
          jsonEncode({
            'formatVersion': currentBackupFormatVersion,
            'appVersion': manifest.appVersion,
            'createdAt': manifest.createdAt.toUtc().toIso8601String(),
          }),
          importedAt,
        ],
      );
    });

    final availableCount = archiveLinksToWrite
        .where((entry) => entry.status != ImportedArchiveStatus.missing)
        .length;
    return BackupV2ImportResult(
      historyCount: projection.history.length,
      favoriteCollectionCount: projection.favorites.length,
      localComicCount: projection.localComics.length,
      sourceCount: projection.sources.length,
      availableArchiveCount: availableCount,
      missingArchiveCount: archiveLinksToWrite.length - availableCount,
    );
  }

  Future<List<ImportedArchiveLink>> archiveLinks({
    ImportedArchiveStatus? status,
  }) async {
    final rows = status == null
        ? await database.raw.getAll(
            'SELECT * FROM local_archive_links ORDER BY comic_id',
          )
        : await database.raw.getAll(
            '''
            SELECT * FROM local_archive_links
            WHERE status = ? ORDER BY comic_id
            ''',
            [status.name],
          );
    return rows
        .map((row) => ImportedArchiveLink.fromRow(row))
        .toList(growable: false);
  }

  /// Records a user-selected archive without modifying that archive.
  /// The companion manifest must identify the same comic and the ZIP size must
  /// match the backup index when an expected size is available.
  Future<ImportedArchiveLink> relinkArchive({
    required String comicId,
    required Object comicType,
    required String archivePath,
  }) async {
    final normalizedType = comicType.toString();
    final identityKey = _localIdentity(comicId, normalizedType);
    final row = await database.raw.getOptional(
      'SELECT * FROM local_archive_links WHERE identity_key = ?',
      [identityKey],
    );
    if (row == null) {
      throw StateError('No imported local comic matches this archive');
    }
    final link = ImportedArchiveLink.fromRow(row);
    final normalizedPath = p.normalize(p.absolute(archivePath));
    if (!_archivePairMatches(
      normalizedPath,
      expectedLength: link.expectedLength,
      comicId: link.comicId,
      comicType: link.comicType,
    )) {
      throw const FormatException(
        'The selected ZIP or its manifest does not match this comic',
      );
    }
    final updatedAt = _clock().toUtc().millisecondsSinceEpoch;
    await database.raw.execute(
      '''
      UPDATE local_archive_links
      SET resolved_path = ?, status = 'relinked', updated_at = ?
      WHERE identity_key = ?
      ''',
      [normalizedPath, updatedAt, identityKey],
    );
    return ImportedArchiveLink(
      identityKey: link.identityKey,
      comicId: link.comicId,
      comicType: link.comicType,
      directory: link.directory,
      originalRoot: link.originalRoot,
      relativePath: link.relativePath,
      originalPath: link.originalPath,
      expectedLength: link.expectedLength,
      resolvedPath: normalizedPath,
      status: ImportedArchiveStatus.relinked,
      updatedAtMillis: updatedAt,
    );
  }

  /// Rechecks recorded locations after a local-library path change.
  Future<List<ImportedArchiveLink>> scanArchiveAvailability({
    String? localRoot,
  }) async {
    final current = await archiveLinks();
    if (current.isEmpty) return const [];
    final updatedAt = _clock().toUtc().millisecondsSinceEpoch;
    final next = current
        .map((link) {
          String? resolved;
          var status = ImportedArchiveStatus.missing;
          if (link.status == ImportedArchiveStatus.relinked &&
              link.resolvedPath != null &&
              _archivePairMatches(
                link.resolvedPath!,
                expectedLength: link.expectedLength,
                comicId: link.comicId,
                comicType: link.comicType,
              )) {
            resolved = link.resolvedPath;
            status = ImportedArchiveStatus.relinked;
          } else {
            resolved = _findMatchingArchive(
              localRootOverride: localRoot,
              originalRoot: link.originalRoot,
              relativePath: link.relativePath,
              originalPath: link.originalPath,
              expectedLength: link.expectedLength,
              comicId: link.comicId,
              comicType: link.comicType,
            );
            if (resolved != null) status = ImportedArchiveStatus.available;
          }
          return ImportedArchiveLink(
            identityKey: link.identityKey,
            comicId: link.comicId,
            comicType: link.comicType,
            directory: link.directory,
            originalRoot: link.originalRoot,
            relativePath: link.relativePath,
            originalPath: link.originalPath,
            expectedLength: link.expectedLength,
            resolvedPath: resolved,
            status: status,
            updatedAtMillis: updatedAt,
          );
        })
        .toList(growable: false);
    await database.raw.writeTransaction((tx) async {
      await tx.executeBatch(
        '''
        UPDATE local_archive_links
        SET resolved_path = ?, status = ?, updated_at = ?
        WHERE identity_key = ?
        ''',
        next
            .map(
              (link) => <Object?>[
                link.resolvedPath,
                link.status.name,
                link.updatedAtMillis,
                link.identityKey,
              ],
            )
            .toList(growable: false),
      );
    });
    return next;
  }

  _ArchiveLinkProjection _buildArchiveLink(
    _LocalComicProjection comic, {
    required String? importedRootOverride,
    required String? previousRelink,
    required int updatedAt,
  }) {
    if (previousRelink != null &&
        _archivePairMatches(
          previousRelink,
          expectedLength: comic.expectedArchiveLength,
          comicId: comic.comicId,
          comicType: comic.comicType,
        )) {
      return _ArchiveLinkProjection(
        comic: comic,
        resolvedPath: previousRelink,
        status: ImportedArchiveStatus.relinked,
        updatedAt: updatedAt,
      );
    }
    final resolved = _findMatchingArchive(
      localRootOverride: importedRootOverride,
      originalRoot: comic.originalRoot,
      relativePath: comic.relativeArchivePath,
      originalPath: comic.originalArchivePath,
      expectedLength: comic.expectedArchiveLength,
      comicId: comic.comicId,
      comicType: comic.comicType,
    );
    return _ArchiveLinkProjection(
      comic: comic,
      resolvedPath: resolved,
      status: resolved == null
          ? ImportedArchiveStatus.missing
          : ImportedArchiveStatus.available,
      updatedAt: updatedAt,
    );
  }
}

final class _BackupProjection {
  const _BackupProjection({
    required this.appState,
    required this.history,
    required this.favorites,
    required this.localComics,
    required this.sources,
  });

  final Map<String, Object?> appState;
  final List<_HistoryProjection> history;
  final Map<String, Object?> favorites;
  final List<_LocalComicProjection> localComics;
  final List<_SourceProjection> sources;

  factory _BackupProjection.parse({
    required Map<String, Uint8List> payloads,
    required Map<String, BackupEntryV2> entriesByPath,
  }) {
    final appdata = _optionalJson(payloads, 'appdata.json');
    if (appdata != null && appdata is! Map) {
      throw const FormatException('logical/appdata.json must be an object');
    }
    final appState = appdata == null
        ? <String, Object?>{}
        : _stringKeyedMap(appdata, path: 'logical/appdata.json');

    final historyValue = _optionalJson(payloads, 'history.json') ?? const [];
    if (historyValue is! List) {
      throw const FormatException('logical/history.json must be an array');
    }
    final history = <_HistoryProjection>[];
    final historyKeys = <String>{};
    for (var index = 0; index < historyValue.length; index++) {
      final row = _stringKeyedMap(
        historyValue[index],
        path: 'logical/history.json[$index]',
      );
      final comicId = _requiredString(row['id'], 'history[$index].id');
      final sourceKey = _requiredString(
        row['source_key'] ?? row['sourceKey'],
        'history[$index].source_key',
      );
      final identity = ComicKey(
        sourceKey: sourceKey,
        comicId: comicId,
      ).storageKey;
      if (!historyKeys.add(identity)) {
        throw FormatException('Duplicate history identity: $identity');
      }
      history.add(
        _HistoryProjection(
          identityKey: identity,
          sourceKey: sourceKey,
          comicId: comicId,
          payloadJson: jsonEncode(row),
        ),
      );
    }

    final favoritesValue =
        _optionalJson(payloads, 'favorites.json') ?? const {};
    if (favoritesValue is! Map) {
      throw const FormatException('logical/favorites.json must be an object');
    }
    final favorites = _stringKeyedMap(
      favoritesValue,
      path: 'logical/favorites.json',
    );

    final localValue = _optionalJson(payloads, 'local_index.json') ?? const {};
    if (localValue is! Map) {
      throw const FormatException('logical/local_index.json must be an object');
    }
    final localIndex = _stringKeyedMap(
      localValue,
      path: 'logical/local_index.json',
    );
    final originalRoot = localIndex['localRoot'] is String
        ? localIndex['localRoot'] as String
        : null;
    final comicsValue = localIndex['comics'] ?? const [];
    if (comicsValue is! List) {
      throw const FormatException('local_index.comics must be an array');
    }
    final localComics = <_LocalComicProjection>[];
    final localKeys = <String>{};
    for (var index = 0; index < comicsValue.length; index++) {
      final row = _stringKeyedMap(
        comicsValue[index],
        path: 'local_index.comics[$index]',
      );
      final comicId = _requiredString(row['id'], 'local comic id');
      final rawComicType = row['comic_type'] ?? row['comicType'];
      if (rawComicType == null || rawComicType is Map || rawComicType is List) {
        throw FormatException('Invalid comic_type for local comic $comicId');
      }
      final comicType = rawComicType.toString();
      final directory = _requiredString(
        row['directory'],
        'local comic directory',
        allowEmpty: true,
      );
      final identity = _localIdentity(comicId, comicType);
      if (!localKeys.add(identity)) {
        throw FormatException('Duplicate local comic identity: $identity');
      }
      final archiveValue = row['archive'];
      final archive = archiveValue == null
          ? const <String, Object?>{}
          : _stringKeyedMap(archiveValue, path: 'local comic archive metadata');
      var relativePath = _optionalString(archive['relativePath']);
      var originalPath = _optionalString(archive['originalPath']);
      if (relativePath == null &&
          directory.isNotEmpty &&
          !p.isAbsolute(directory) &&
          !directory.startsWith('..')) {
        relativePath = p.posix.join(
          directory.replaceAll('\\', '/'),
          '.venera',
          'archive.zip',
        );
      } else if (originalPath == null && p.isAbsolute(directory)) {
        originalPath = p.join(directory, '.venera', 'archive.zip');
      }
      localComics.add(
        _LocalComicProjection(
          identityKey: identity,
          comicId: comicId,
          comicType: comicType,
          directory: directory,
          payloadJson: jsonEncode(row),
          originalRoot: originalRoot,
          relativeArchivePath: relativePath,
          originalArchivePath: originalPath,
          expectedArchiveLength: _optionalNonNegativeInt(archive['length']),
        ),
      );
    }

    final sourceValue = _optionalJson(payloads, 'sources.json') ?? const [];
    if (sourceValue is! List) {
      throw const FormatException('logical/sources.json must be an array');
    }
    final sources = <_SourceProjection>[];
    final sourceNames = <String>{};
    for (var index = 0; index < sourceValue.length; index++) {
      final row = _stringKeyedMap(
        sourceValue[index],
        path: 'logical/sources.json[$index]',
      );
      final name = _requiredString(row['name'], 'source name');
      if (p.basename(name) != name || !sourceNames.add(name)) {
        throw FormatException('Invalid or duplicate source name: $name');
      }
      final digest = _requiredString(row['sha256'], 'source sha256');
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        throw FormatException('Invalid source sha256: $name');
      }
      final length = _requiredNonNegativeInt(row['length'], 'source length');
      final sourcePath = _optionalString(row['path']);
      Uint8List? content;
      if (sourcePath != null) {
        final entry = entriesByPath[sourcePath];
        content = payloads[sourcePath];
        if (entry == null ||
            content == null ||
            entry.kind != 'source_document' ||
            entry.length != length ||
            entry.sha256 != digest) {
          throw FormatException('Source document metadata mismatch: $name');
        }
      }
      sources.add(
        _SourceProjection(
          name: name,
          content: content,
          sha256: digest,
          length: length,
        ),
      );
    }
    return _BackupProjection(
      appState: appState,
      history: history,
      favorites: favorites,
      localComics: localComics,
      sources: sources,
    );
  }
}

final class _HistoryProjection {
  const _HistoryProjection({
    required this.identityKey,
    required this.sourceKey,
    required this.comicId,
    required this.payloadJson,
  });

  final String identityKey;
  final String sourceKey;
  final String comicId;
  final String payloadJson;
}

final class _LocalComicProjection {
  const _LocalComicProjection({
    required this.identityKey,
    required this.comicId,
    required this.comicType,
    required this.directory,
    required this.payloadJson,
    required this.originalRoot,
    required this.relativeArchivePath,
    required this.originalArchivePath,
    required this.expectedArchiveLength,
  });

  final String identityKey;
  final String comicId;
  final String comicType;
  final String directory;
  final String payloadJson;
  final String? originalRoot;
  final String? relativeArchivePath;
  final String? originalArchivePath;
  final int? expectedArchiveLength;
}

final class _SourceProjection {
  const _SourceProjection({
    required this.name,
    required this.content,
    required this.sha256,
    required this.length,
  });

  final String name;
  final Uint8List? content;
  final String sha256;
  final int length;
}

final class _ArchiveLinkProjection {
  const _ArchiveLinkProjection({
    required this.comic,
    required this.resolvedPath,
    required this.status,
    required this.updatedAt,
  });

  final _LocalComicProjection comic;
  final String? resolvedPath;
  final ImportedArchiveStatus status;
  final int updatedAt;

  List<Object?> get parameters => [
    comic.identityKey,
    comic.comicId,
    comic.comicType,
    comic.directory,
    comic.originalRoot,
    comic.relativeArchivePath,
    comic.originalArchivePath,
    comic.expectedArchiveLength,
    resolvedPath,
    status.name,
    updatedAt,
  ];
}

Object? _optionalJson(Map<String, Uint8List> payloads, String fileName) {
  final bytes = payloads['$backupLogicalDirectory/$fileName'];
  if (bytes == null) return null;
  try {
    return jsonDecode(utf8.decode(bytes));
  } catch (error) {
    throw FormatException('Invalid logical/$fileName JSON', error);
  }
}

Map<String, Object?> _stringKeyedMap(Object? value, {required String path}) {
  if (value is! Map) throw FormatException('$path must be an object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path contains a non-string key');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _requiredString(Object? value, String field, {bool allowEmpty = false}) {
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw FormatException('Invalid $field');
  }
  return value;
}

String? _optionalString(Object? value) {
  return value is String && value.isNotEmpty ? value : null;
}

int _requiredNonNegativeInt(Object? value, String field) {
  final result = _optionalNonNegativeInt(value);
  if (result == null) throw FormatException('Invalid $field');
  return result;
}

int? _optionalNonNegativeInt(Object? value) {
  final result = switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text),
    _ => null,
  };
  return result != null && result >= 0 ? result : null;
}

String _localIdentity(String comicId, String comicType) {
  return jsonEncode([comicType, comicId]);
}

String? _findMatchingArchive({
  required String? localRootOverride,
  required String? originalRoot,
  required String? relativePath,
  required String? originalPath,
  required int? expectedLength,
  required String comicId,
  required String comicType,
}) {
  final candidates = <String>[];
  void addRelativeCandidate(String? root) {
    if (root == null || root.isEmpty || relativePath == null) return;
    final normalizedRelative = p.normalize(relativePath);
    if (p.isAbsolute(normalizedRelative) ||
        normalizedRelative == '..' ||
        normalizedRelative.startsWith('${p.separator}..') ||
        normalizedRelative.startsWith('..${p.separator}')) {
      return;
    }
    final normalizedRoot = p.normalize(p.absolute(root));
    final candidate = p.normalize(p.join(normalizedRoot, normalizedRelative));
    if (candidate == normalizedRoot || p.isWithin(normalizedRoot, candidate)) {
      candidates.add(candidate);
    }
  }

  addRelativeCandidate(localRootOverride);
  if (originalRoot != localRootOverride) addRelativeCandidate(originalRoot);
  if (originalPath != null && p.isAbsolute(originalPath)) {
    candidates.add(p.normalize(originalPath));
  }
  // Early development builds wrote absolute external paths into the field
  // named `relativePath`; accept that shape without treating it as managed.
  if (relativePath != null && p.isAbsolute(relativePath)) {
    candidates.add(p.normalize(relativePath));
  }
  for (final candidate in candidates.toSet()) {
    if (_archivePairMatches(
      candidate,
      expectedLength: expectedLength,
      comicId: comicId,
      comicType: comicType,
    )) {
      return candidate;
    }
  }
  return null;
}

bool _archivePairMatches(
  String archivePath, {
  required int? expectedLength,
  required String comicId,
  required String comicType,
}) {
  try {
    final archive = File(archivePath);
    if (!archive.existsSync() ||
        archive.statSync().type != FileSystemEntityType.file ||
        (expectedLength != null && archive.lengthSync() != expectedLength)) {
      return false;
    }
    final manifest = File(p.join(archive.parent.path, 'manifest.json'));
    if (!manifest.existsSync()) return false;
    final decoded = jsonDecode(manifest.readAsStringSync());
    if (decoded is! Map || decoded['comic'] is! Map) return false;
    final comic = decoded['comic'] as Map;
    return comic['id']?.toString() == comicId &&
        comic['comicType']?.toString() == comicType;
  } catch (_) {
    return false;
  }
}
