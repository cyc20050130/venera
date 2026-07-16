import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/io.dart';

class ComicDetailsRepository {
  ComicDetailsRepository._create();

  static ComicDetailsRepository? _instance;

  factory ComicDetailsRepository() {
    return _instance ??= ComicDetailsRepository._create();
  }

  static const freshCacheDuration = Duration(minutes: 10);

  static const staleFallbackDuration = Duration(hours: 24);

  Database? _db;

  Future<void>? _initFuture;

  final Map<String, Future<void>> _backgroundRefreshTasks = {};

  Future<void> init() async {
    if (_db != null) {
      return;
    }
    if (_initFuture != null) {
      return _initFuture!;
    }
    _initFuture = Future(() async {
      final db = sqlite3.open(FilePath.join(App.dataPath, 'comic_details.db'));
      db.execute('''
        CREATE TABLE IF NOT EXISTS comic_details_cache (
          source_key TEXT NOT NULL,
          comic_id TEXT NOT NULL,
          payload TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          fresh_until INTEGER NOT NULL,
          PRIMARY KEY (source_key, comic_id)
        );
      ''');
      _db = db;
    });
    try {
      await _initFuture;
    } finally {
      _initFuture = null;
    }
  }

  Future<Res<ComicDetails>> load(
    String sourceKey,
    String comicId, {
    bool forceRefresh = false,
    bool refreshIfStale = true,
    Duration freshFor = freshCacheDuration,
    Duration staleFallback = staleFallbackDuration,
    FutureOr<void> Function(ComicDetails details)? onBackgroundUpdate,
  }) async {
    final stopwatch = Stopwatch()..start();
    await init();

    final source = ComicSource.find(sourceKey);
    if (source == null || source.loadComicInfo == null) {
      return const Res.error('Comic source not found');
    }

    final key = _buildKey(sourceKey, comicId);
    final now = DateTime.now();
    final cached = forceRefresh ? null : _findCache(sourceKey, comicId);

    if (!forceRefresh && cached != null) {
      if (cached.isFresh(now)) {
        stopwatch.stop();
        _logPerf(
          'load hit fresh cache',
          stopwatch,
          sourceKey: sourceKey,
          comicId: comicId,
        );
        return Res(cached.details);
      }

      if (refreshIfStale) {
        _scheduleBackgroundRefresh(
          key,
          source,
          comicId,
          freshFor,
          cached.payload,
          onBackgroundUpdate,
        );
        stopwatch.stop();
        _logPerf(
          'load hit stale cache',
          stopwatch,
          sourceKey: sourceKey,
          comicId: comicId,
        );
        return Res(cached.details);
      }
    }

    final network = await _fetchAndStore(source, comicId, freshFor);

    if (network.result.success) {
      stopwatch.stop();
      _logPerf(
        'load fetched network',
        stopwatch,
        sourceKey: sourceKey,
        comicId: comicId,
      );
      return network.result;
    }

    if (cached != null && cached.canFallback(now, staleFallback)) {
      stopwatch.stop();
      _logPerf(
        'load fallback stale cache',
        stopwatch,
        sourceKey: sourceKey,
        comicId: comicId,
      );
      return Res(cached.details);
    }

    stopwatch.stop();
    _logPerf('load failed', stopwatch, sourceKey: sourceKey, comicId: comicId);
    return network.result;
  }

  Future<void> refresh(
    String sourceKey,
    String comicId, {
    Duration freshFor = freshCacheDuration,
  }) async {
    await init();
    final source = ComicSource.find(sourceKey);
    if (source == null || source.loadComicInfo == null) {
      return;
    }
    await _fetchAndStore(source, comicId, freshFor);
  }

  Future<void> save(
    ComicDetails details, {
    Duration freshFor = freshCacheDuration,
  }) async {
    await init();
    _saveCache(details, freshFor, payload: _encodeDetails(details));
  }

  Future<void> delete(String sourceKey, String comicId) async {
    await init();
    _db!.execute(
      '''
      DELETE FROM comic_details_cache
      WHERE source_key = ? AND comic_id = ?;
      ''',
      [sourceKey, comicId],
    );
  }

  _CachedComicDetails? _findCache(String sourceKey, String comicId) {
    final result = _db!.select(
      '''
      SELECT payload, updated_at, fresh_until
      FROM comic_details_cache
      WHERE source_key = ? AND comic_id = ?;
      ''',
      [sourceKey, comicId],
    );
    if (result.isEmpty) {
      return null;
    }
    try {
      final row = result.first;
      final payload = _cachePayload(row);
      final updatedAt = _cacheTimestamp(row, 'updated_at');
      final freshUntil = _cacheTimestamp(row, 'fresh_until');
      if (payload == null || updatedAt == null || freshUntil == null) {
        throw const FormatException('Invalid cached comic details row');
      }
      return _CachedComicDetails(
        ComicDetails.fromJson(Map<String, dynamic>.from(jsonDecode(payload))),
        DateTime.fromMillisecondsSinceEpoch(updatedAt),
        DateTime.fromMillisecondsSinceEpoch(freshUntil),
        payload,
      );
    } catch (e, s) {
      Log.error(
        'ComicDetailsRepository',
        'Failed to parse cached details for $sourceKey@$comicId: $e',
        s,
      );
      _db!.execute(
        '''
        DELETE FROM comic_details_cache
        WHERE source_key = ? AND comic_id = ?;
        ''',
        [sourceKey, comicId],
      );
      return null;
    }
  }

  void _saveCache(ComicDetails details, Duration freshFor, {String? payload}) {
    final now = DateTime.now();
    payload ??= _encodeDetails(details);
    _db!.execute(
      '''
      INSERT OR REPLACE INTO comic_details_cache (
        source_key,
        comic_id,
        payload,
        updated_at,
        fresh_until
      ) VALUES (?, ?, ?, ?, ?);
      ''',
      [
        details.sourceKey,
        details.id,
        payload,
        now.millisecondsSinceEpoch,
        now.add(freshFor).millisecondsSinceEpoch,
      ],
    );
  }

  Future<_StoredFetchResult<ComicDetails>> _fetchAndStore(
    ComicSource source,
    String comicId,
    Duration freshFor,
  ) async {
    try {
      final result = await source.loadComicInfo!(comicId);
      if (result.error) {
        return _StoredFetchResult(Res.fromErrorRes(result), false);
      }
      final payload = _encodeDetails(result.data);
      final previousPayload = _readPayload(source.key, comicId);
      final changed = previousPayload != payload;
      _saveCache(result.data, freshFor, payload: payload);
      return _StoredFetchResult(Res(result.data), changed);
    } catch (e, s) {
      Log.error(
        'ComicDetailsRepository',
        'Failed to fetch details for ${source.key}@$comicId: $e',
        s,
      );
      return _StoredFetchResult(Res.error(e.toString()), false);
    }
  }

  void _scheduleBackgroundRefresh(
    String key,
    ComicSource source,
    String comicId,
    Duration freshFor,
    String cachedPayload,
    FutureOr<void> Function(ComicDetails details)? onBackgroundUpdate,
  ) {
    if (_backgroundRefreshTasks.containsKey(key)) {
      return;
    }
    _backgroundRefreshTasks[key] = Future(() async {
      try {
        final result = await _fetchAndStore(source, comicId, freshFor);
        if (result.result.success) {
          if (result.changed) {
            _logBackgroundRefresh(
              'details background refresh changed',
              source.key,
              comicId,
            );
            if (onBackgroundUpdate != null) {
              await onBackgroundUpdate(result.result.data);
            }
          } else if (cachedPayload.isNotEmpty) {
            _logBackgroundRefresh(
              'details background refresh skipped',
              source.key,
              comicId,
            );
          }
        }
      } catch (e, s) {
        Log.error(
          'ComicDetailsRepository',
          'Background refresh failed for $key: $e',
          s,
        );
      } finally {
        _backgroundRefreshTasks.remove(key);
      }
    });
  }

  String _buildKey(String sourceKey, String comicId) => '$sourceKey@$comicId';

  String _encodeDetails(ComicDetails details) => jsonEncode(details.toJson());

  String? _readPayload(String sourceKey, String comicId) {
    final result = _db!.select(
      '''
      SELECT payload
      FROM comic_details_cache
      WHERE source_key = ? AND comic_id = ?;
      ''',
      [sourceKey, comicId],
    );
    if (result.isEmpty) {
      return null;
    }
    return _cachePayload(result.first);
  }

  String? _cachePayload(Row row) {
    final payload = row['payload'];
    return payload is String ? payload : null;
  }

  int? _cacheTimestamp(Row row, String key) {
    final timestamp = row[key];
    return timestamp is int ? timestamp : null;
  }

  void _logPerf(
    String label,
    Stopwatch stopwatch, {
    required String sourceKey,
    required String comicId,
  }) {
    if (!kDebugMode) {
      return;
    }
    Log.info(
      'ComicDetailsRepository',
      '[perf] $label ${stopwatch.elapsedMilliseconds}ms $sourceKey@$comicId',
    );
  }

  void _logBackgroundRefresh(String label, String sourceKey, String comicId) {
    if (!kDebugMode) {
      return;
    }
    Log.info('ComicDetailsRepository', '[perf] $label $sourceKey@$comicId');
  }

  @visibleForTesting
  void debugReset() {
    _db?.close();
    _db = null;
    _initFuture = null;
    _backgroundRefreshTasks.clear();
  }
}

class _CachedComicDetails {
  const _CachedComicDetails(
    this.details,
    this.updatedAt,
    this.freshUntil,
    this.payload,
  );

  final ComicDetails details;

  final DateTime updatedAt;

  final DateTime freshUntil;

  final String payload;

  bool isFresh(DateTime now) => !freshUntil.isBefore(now);

  bool canFallback(DateTime now, Duration maxAge) {
    return now.difference(updatedAt) <= maxAge;
  }
}

class _StoredFetchResult<T> {
  const _StoredFetchResult(this.result, this.changed);

  final Res<T> result;
  final bool changed;
}
