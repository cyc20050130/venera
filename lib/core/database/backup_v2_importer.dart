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
    required this.imageFavoriteCount,
    required this.imageFavoriteAssetCount,
    required this.favoriteCollectionCount,
    required this.cookieCount,
    required this.downloadTaskCount,
    required this.localComicCount,
    required this.sourceCount,
    required this.availableArchiveCount,
    required this.missingArchiveCount,
  });

  final int historyCount;
  final int imageFavoriteCount;
  final int imageFavoriteAssetCount;
  final int favoriteCollectionCount;
  final int cookieCount;
  final int downloadTaskCount;
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
      // Compatibility databases and image-favorite assets have already been
      // checksum-validated as files. Keeping them out of this map prevents a
      // full backup from being duplicated in memory and then in venera.db.
      if (entry.path.startsWith('$backupLogicalDirectory/') &&
          entry.kind != 'image_favorite_asset') {
        payloads[entry.path] = File(
          p.joinAll([directory.path, ...entry.path.split('/')]),
        ).readAsBytesSync();
      }
    }

    final projection = _BackupProjection.parse(
      payloads: payloads,
      entriesByPath: entriesByPath,
    );
    bool hasLogicalPayload(String name) =>
        payloads.containsKey('$backupLogicalDirectory/$name');
    final importsAppState = hasLogicalPayload('appdata.json');
    final importsImplicitData = hasLogicalPayload('implicit_data.json');
    final importsImageFavorites = hasLogicalPayload('image_favorites.json');
    final importsCookies = hasLogicalPayload('cookies.json');
    final importsDownloadTasks = hasLogicalPayload('download_tasks.json');
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
      if (!comic.expectsArchive) continue;
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
      if (importsAppState) {
        if (importsImplicitData) {
          await tx.execute('DELETE FROM app_state');
        } else {
          await tx.execute(
            "DELETE FROM app_state WHERE section_key <> 'implicitData'",
          );
        }
      } else if (importsImplicitData) {
        await tx.execute(
          "DELETE FROM app_state WHERE section_key = 'implicitData'",
        );
      }
      await tx.execute('DELETE FROM reading_history');
      if (importsImageFavorites) {
        await tx.execute('DELETE FROM image_favorites');
      }
      await tx.execute('DELETE FROM favorite_collections');
      if (importsCookies) await tx.execute('DELETE FROM cookies');
      if (importsDownloadTasks) await tx.execute('DELETE FROM download_tasks');
      await tx.execute('DELETE FROM local_comics');
      await tx.execute('DELETE FROM local_archive_links');
      await tx.execute('DELETE FROM source_documents');

      if (projection.appState.isNotEmpty) {
        await tx.executeBatch(
          'INSERT OR REPLACE INTO app_state(section_key, payload_json) '
          'VALUES (?, ?)',
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
      if (projection.imageFavorites.isNotEmpty) {
        await tx.executeBatch(
          '''
          INSERT INTO image_favorites(
            identity_key, source_key, comic_id, payload_json
          ) VALUES (?, ?, ?, ?)
          ''',
          projection.imageFavorites
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
      if (projection.cookies.isNotEmpty) {
        await tx.executeBatch(
          '''
          INSERT INTO cookies(
            name, value, domain, path, expires, secure, http_only
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ''',
          projection.cookies
              .map((entry) => entry.parameters)
              .toList(growable: false),
        );
      }
      if (projection.downloadTasks.isNotEmpty) {
        await tx.executeBatch(
          '''
          INSERT INTO download_tasks(
            task_id, source_key, comic_id, chapter_id, state,
            completed_units, total_units, payload_json, created_at, updated_at
          ) VALUES (?, ?, ?, ?, 'paused', ?, ?, ?, ?, ?)
          ''',
          projection.downloadTasks
              .map(
                (entry) => <Object?>[
                  entry.taskId,
                  entry.sourceKey,
                  entry.comicId,
                  entry.chapterId,
                  entry.completedUnits,
                  entry.totalUnits,
                  entry.payloadJson,
                  importedAt,
                  importedAt,
                ],
              )
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
      imageFavoriteCount: projection.imageFavorites.length,
      imageFavoriteAssetCount: projection.imageFavoriteAssets.length,
      favoriteCollectionCount: projection.favorites.length,
      cookieCount: projection.cookies.length,
      downloadTaskCount: projection.downloadTasks.length,
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
    required this.imageFavorites,
    required this.imageFavoriteAssets,
    required this.favorites,
    required this.cookies,
    required this.downloadTasks,
    required this.localComics,
    required this.sources,
  });

  final Map<String, Object?> appState;
  final List<_HistoryProjection> history;
  final List<_ImageFavoriteProjection> imageFavorites;
  final List<_ImageFavoriteAssetProjection> imageFavoriteAssets;
  final Map<String, Object?> favorites;
  final List<_CookieProjection> cookies;
  final List<_DownloadTaskProjection> downloadTasks;
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
    final implicitData = _optionalJson(payloads, 'implicit_data.json');
    if (implicitData != null) {
      appState['implicitData'] = _stringKeyedMap(
        implicitData,
        path: 'logical/implicit_data.json',
      );
    }

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
      final explicitSource = _optionalString(
        row['source_key'] ?? row['sourceKey'],
      );
      final type = _optionalNonNegativeInt(row['type']) ?? 0;
      final sourceKey =
          explicitSource ?? (type == 0 ? 'local' : 'Unknown:$type');
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

    final imageFavoritesValue =
        _optionalJson(payloads, 'image_favorites.json') ?? const [];
    if (imageFavoritesValue is! List) {
      throw const FormatException(
        'logical/image_favorites.json must be an array',
      );
    }
    final imageFavorites = <_ImageFavoriteProjection>[];
    final imageFavoriteKeys = <String>{};
    for (var index = 0; index < imageFavoritesValue.length; index++) {
      final row = _stringKeyedMap(
        imageFavoritesValue[index],
        path: 'logical/image_favorites.json[$index]',
      );
      final comicId = _requiredString(row['id'], 'image favorite[$index].id');
      final sourceKey = _requiredString(
        row['source_key'] ?? row['sourceKey'],
        'image favorite[$index].source_key',
      );
      final identity = ComicKey(
        sourceKey: sourceKey,
        comicId: comicId,
      ).storageKey;
      if (!imageFavoriteKeys.add(identity)) {
        throw FormatException('Duplicate image favorite identity: $identity');
      }
      imageFavorites.add(
        _ImageFavoriteProjection(
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

    final imageFavoriteAssetsValue =
        _optionalJson(payloads, 'image_favorite_assets.json') ?? const [];
    if (imageFavoriteAssetsValue is! List) {
      throw const FormatException(
        'logical/image_favorite_assets.json must be an array',
      );
    }
    final imageFavoriteAssets = <_ImageFavoriteAssetProjection>[];
    final imageFavoriteAssetNames = <String>{};
    final imageFavoriteAssetPaths = <String>{};
    for (var index = 0; index < imageFavoriteAssetsValue.length; index++) {
      final row = _stringKeyedMap(
        imageFavoriteAssetsValue[index],
        path: 'logical/image_favorite_assets.json[$index]',
      );
      final name = _requiredString(
        row['name'],
        'image favorite asset[$index].name',
      );
      if (!_isSafeAssetName(name) ||
          !imageFavoriteAssetNames.add(name.toLowerCase())) {
        throw FormatException(
          'Invalid or duplicate image favorite asset name: $name',
        );
      }
      final assetPath = _requiredString(
        row['path'],
        'image favorite asset[$index].path',
      );
      if (!assetPath.startsWith(
            '$backupLogicalDirectory/image_favorite_assets/',
          ) ||
          !imageFavoriteAssetPaths.add(assetPath)) {
        throw FormatException(
          'Invalid or duplicate image favorite asset path: $assetPath',
        );
      }
      final length = _requiredNonNegativeInt(
        row['length'],
        'image favorite asset[$index].length',
      );
      final digest = _requiredString(
        row['sha256'],
        'image favorite asset[$index].sha256',
      );
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        throw FormatException('Invalid image favorite asset sha256: $name');
      }
      final manifestEntry = entriesByPath[assetPath];
      if (manifestEntry == null ||
          manifestEntry.kind != 'image_favorite_asset' ||
          manifestEntry.length != length ||
          manifestEntry.sha256 != digest) {
        throw FormatException('Image favorite asset metadata mismatch: $name');
      }
      imageFavoriteAssets.add(
        _ImageFavoriteAssetProjection(
          name: name,
          path: assetPath,
          length: length,
          sha256: digest,
        ),
      );
    }
    final unindexedImageAssets = entriesByPath.values
        .where((entry) => entry.kind == 'image_favorite_asset')
        .map((entry) => entry.path)
        .toSet()
        .difference(imageFavoriteAssetPaths);
    if (unindexedImageAssets.isNotEmpty) {
      throw const FormatException('Backup contains unindexed image assets');
    }

    final cookiesValue = _optionalJson(payloads, 'cookies.json') ?? const [];
    if (cookiesValue is! List) {
      throw const FormatException('logical/cookies.json must be an array');
    }
    final cookies = <_CookieProjection>[];
    final cookieKeys = <String>{};
    for (var index = 0; index < cookiesValue.length; index++) {
      final row = _stringKeyedMap(
        cookiesValue[index],
        path: 'logical/cookies.json[$index]',
      );
      final name = _requiredString(row['name'], 'cookie[$index].name');
      final value = _requiredString(
        row['value'],
        'cookie[$index].value',
        allowEmpty: true,
      );
      final domain = _requiredString(row['domain'], 'cookie[$index].domain');
      final path = _requiredString(row['path'] ?? '/', 'cookie[$index].path');
      final expires = row['expires'] == null
          ? null
          : _requiredNonNegativeInt(row['expires'], 'cookie[$index].expires');
      final secure = _requiredFlag(row['secure'], 'cookie[$index].secure');
      final httpOnly = _requiredFlag(
        row['httpOnly'] ?? row['http_only'],
        'cookie[$index].httpOnly',
      );
      final key = jsonEncode([name, domain, path]);
      if (!cookieKeys.add(key)) {
        throw FormatException('Duplicate cookie identity: $key');
      }
      cookies.add(
        _CookieProjection(
          name: name,
          value: value,
          domain: domain,
          path: path,
          expires: expires,
          secure: secure,
          httpOnly: httpOnly,
        ),
      );
    }

    final downloadTasksValue =
        _optionalJson(payloads, 'download_tasks.json') ?? const [];
    if (downloadTasksValue is! List) {
      throw const FormatException(
        'logical/download_tasks.json must be an array',
      );
    }
    final downloadTasks = <_DownloadTaskProjection>[];
    final downloadTaskKeys = <String>{};
    for (var index = 0; index < downloadTasksValue.length; index++) {
      final row = _stringKeyedMap(
        downloadTasksValue[index],
        path: 'logical/download_tasks.json[$index]',
      );
      final type = _requiredString(row['type'], 'download task[$index].type');
      final String sourceKey;
      final String comicId;
      switch (type) {
        case 'ImagesDownloadTask':
          sourceKey = _requiredString(
            row['source'],
            'download task[$index].source',
          );
          comicId = _requiredString(
            row['comicId'],
            'download task[$index].comicId',
          );
        case 'ArchiveDownloadTask':
          final comic = _stringKeyedMap(
            row['comic'],
            path: 'download task[$index].comic',
          );
          sourceKey = _requiredString(
            comic['sourceKey'] ?? comic['source_key'],
            'download task[$index].comic.sourceKey',
          );
          comicId = _requiredString(
            comic['id'],
            'download task[$index].comic.id',
          );
        default:
          throw FormatException('Unsupported download task type: $type');
      }
      final taskId = ComicKey(
        sourceKey: sourceKey,
        comicId: comicId,
      ).storageKey;
      if (!downloadTaskKeys.add(taskId)) {
        throw FormatException('Duplicate download task identity: $taskId');
      }
      var completedUnits = _optionalNonNegativeInt(row['downloadedCount']) ?? 0;
      var totalUnits = _optionalNonNegativeInt(row['totalCount']);
      if (totalUnits != null && completedUnits > totalUnits) {
        completedUnits = totalUnits;
      }
      downloadTasks.add(
        _DownloadTaskProjection(
          taskId: taskId,
          sourceKey: sourceKey,
          comicId: comicId,
          chapterId: null,
          completedUnits: completedUnits,
          totalUnits: totalUnits,
          payloadJson: jsonEncode(row),
        ),
      );
    }

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
      final expectsArchive =
          archive['exists'] == true ||
          (!archive.containsKey('exists') && archive['length'] != null);
      var relativePath = expectsArchive
          ? _optionalString(archive['relativePath'])
          : null;
      var originalPath = expectsArchive
          ? _optionalString(archive['originalPath'])
          : null;
      if (expectsArchive) {
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
      }
      localComics.add(
        _LocalComicProjection(
          identityKey: identity,
          comicId: comicId,
          comicType: comicType,
          directory: directory,
          payloadJson: jsonEncode(row),
          expectsArchive: expectsArchive,
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
      imageFavorites: imageFavorites,
      imageFavoriteAssets: imageFavoriteAssets,
      favorites: favorites,
      cookies: cookies,
      downloadTasks: downloadTasks,
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

final class _ImageFavoriteProjection {
  const _ImageFavoriteProjection({
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

final class _ImageFavoriteAssetProjection {
  const _ImageFavoriteAssetProjection({
    required this.name,
    required this.path,
    required this.length,
    required this.sha256,
  });

  final String name;
  final String path;
  final int length;
  final String sha256;
}

final class _CookieProjection {
  const _CookieProjection({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.expires,
    required this.secure,
    required this.httpOnly,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final int? expires;
  final int secure;
  final int httpOnly;

  List<Object?> get parameters => [
    name,
    value,
    domain,
    path,
    expires,
    secure,
    httpOnly,
  ];
}

final class _DownloadTaskProjection {
  const _DownloadTaskProjection({
    required this.taskId,
    required this.sourceKey,
    required this.comicId,
    required this.chapterId,
    required this.completedUnits,
    required this.totalUnits,
    required this.payloadJson,
  });

  final String taskId;
  final String sourceKey;
  final String comicId;
  final String? chapterId;
  final int completedUnits;
  final int? totalUnits;
  final String payloadJson;
}

final class _LocalComicProjection {
  const _LocalComicProjection({
    required this.identityKey,
    required this.comicId,
    required this.comicType,
    required this.directory,
    required this.payloadJson,
    required this.expectsArchive,
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
  final bool expectsArchive;
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

int _requiredFlag(Object? value, String field) {
  return switch (value) {
    true || 1 || '1' => 1,
    null || false || 0 || '0' => 0,
    _ => throw FormatException('Invalid $field'),
  };
}

bool _isSafeAssetName(String value) {
  return normalizeBackupEntryPath(value) == value &&
      !value.contains('/') &&
      !value.contains('\\') &&
      p.basename(value) == value;
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
        archive.statSync().type != FileSystemEntityType.file) {
      return false;
    }
    // Recompression legitimately changes the ZIP length. The companion
    // manifest identity is authoritative; [expectedLength] remains useful as
    // display/provenance metadata but must not prevent automatic relinking.
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
