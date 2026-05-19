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

    final network = await _fetchAndStore(
      source,
      comicId,
      freshFor,
    );

    if (network.success) {
      stopwatch.stop();
      _logPerf(
        'load fetched network',
        stopwatch,
        sourceKey: sourceKey,
        comicId: comicId,
      );
      return network;
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
    _logPerf(
      'load failed',
      stopwatch,
      sourceKey: sourceKey,
      comicId: comicId,
    );
    return network;
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
    _saveCache(details, freshFor);
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
      return _CachedComicDetails(
        ComicDetails.fromJson(
          Map<String, dynamic>.from(jsonDecode(row['payload'] as String)),
        ),
        DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
        DateTime.fromMillisecondsSinceEpoch(row['fresh_until'] as int),
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

  void _saveCache(ComicDetails details, Duration freshFor) {
    final now = DateTime.now();
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
        jsonEncode(details.toJson()),
        now.millisecondsSinceEpoch,
        now.add(freshFor).millisecondsSinceEpoch,
      ],
    );
  }

  Future<Res<ComicDetails>> _fetchAndStore(
    ComicSource source,
    String comicId,
    Duration freshFor,
  ) async {
    try {
      final result = await source.loadComicInfo!(comicId);
      if (result.error) {
        return Res.fromErrorRes(result);
      }
      _saveCache(result.data, freshFor);
      return Res(result.data);
    } catch (e, s) {
      Log.error(
        'ComicDetailsRepository',
        'Failed to fetch details for ${source.key}@$comicId: $e',
        s,
      );
      return Res.error(e.toString());
    }
  }

  void _scheduleBackgroundRefresh(
    String key,
    ComicSource source,
    String comicId,
    Duration freshFor,
    FutureOr<void> Function(ComicDetails details)? onBackgroundUpdate,
  ) {
    if (_backgroundRefreshTasks.containsKey(key)) {
      return;
    }
    _backgroundRefreshTasks[key] = Future(() async {
      try {
        final result = await _fetchAndStore(source, comicId, freshFor);
        if (result.success && onBackgroundUpdate != null) {
          await onBackgroundUpdate(result.data);
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
}

class _CachedComicDetails {
  const _CachedComicDetails(this.details, this.updatedAt, this.freshUntil);

  final ComicDetails details;

  final DateTime updatedAt;

  final DateTime freshUntil;

  bool isFresh(DateTime now) => !freshUntil.isBefore(now);

  bool canFallback(DateTime now, Duration maxAge) {
    return now.difference(updatedAt) <= maxAge;
  }
}
