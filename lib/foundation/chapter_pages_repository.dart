import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/io.dart';

class ChapterPagesRepository {
  ChapterPagesRepository._create();

  static ChapterPagesRepository? _instance;

  factory ChapterPagesRepository() {
    return _instance ??= ChapterPagesRepository._create();
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
        CREATE TABLE IF NOT EXISTS chapter_pages_cache (
          source_key TEXT NOT NULL,
          comic_id TEXT NOT NULL,
          chapter_id TEXT NOT NULL,
          payload TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          fresh_until INTEGER NOT NULL,
          PRIMARY KEY (source_key, comic_id, chapter_id)
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

  Future<Res<List<String>>> load(
    String sourceKey,
    String comicId,
    String? chapterId, {
    bool forceRefresh = false,
    bool refreshIfStale = true,
    Duration freshFor = freshCacheDuration,
    Duration staleFallback = staleFallbackDuration,
    FutureOr<void> Function(List<String> pages)? onBackgroundUpdate,
  }) async {
    final stopwatch = Stopwatch()..start();
    await init();

    final source = ComicSource.find(sourceKey);
    if (source == null || source.loadComicPages == null) {
      return const Res.error('Comic source not found');
    }

    final normalizedChapterId = chapterId ?? '0';
    final key = _buildKey(sourceKey, comicId, normalizedChapterId);
    final now = DateTime.now();
    final cached = forceRefresh
        ? null
        : _findCache(sourceKey, comicId, normalizedChapterId);

    if (!forceRefresh && cached != null) {
      if (cached.isFresh(now)) {
        stopwatch.stop();
        _logPerf(
          'load hit fresh cache',
          stopwatch,
          sourceKey: sourceKey,
          comicId: comicId,
          chapterId: normalizedChapterId,
        );
        return Res(cached.pages);
      }

      if (refreshIfStale) {
        _scheduleBackgroundRefresh(
          key,
          source,
          comicId,
          chapterId,
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
          chapterId: normalizedChapterId,
        );
        return Res(cached.pages);
      }
    }

    final network = await _fetchAndStore(source, comicId, chapterId, freshFor);

    if (network.result.success) {
      stopwatch.stop();
      _logPerf(
        'load fetched network',
        stopwatch,
        sourceKey: sourceKey,
        comicId: comicId,
        chapterId: normalizedChapterId,
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
        chapterId: normalizedChapterId,
      );
      return Res(cached.pages);
    }

    stopwatch.stop();
    _logPerf(
      'load failed',
      stopwatch,
      sourceKey: sourceKey,
      comicId: comicId,
      chapterId: normalizedChapterId,
    );
    return network.result;
  }

  Future<void> prefetch(
    String sourceKey,
    String comicId,
    String? chapterId, {
    Duration freshFor = freshCacheDuration,
  }) async {
    await init();
    final source = ComicSource.find(sourceKey);
    if (source == null || source.loadComicPages == null) {
      return;
    }
    final normalizedChapterId = chapterId ?? '0';
    final cached = _findCache(sourceKey, comicId, normalizedChapterId);
    final now = DateTime.now();
    if (cached != null && cached.isFresh(now)) {
      return;
    }
    if (cached != null) {
      _scheduleBackgroundRefresh(
        _buildKey(sourceKey, comicId, normalizedChapterId),
        source,
        comicId,
        chapterId,
        freshFor,
        cached.payload,
        null,
      );
      return;
    }
    await _fetchAndStore(source, comicId, chapterId, freshFor);
  }

  Future<_StoredFetchResult<List<String>>> _fetchAndStore(
    ComicSource source,
    String comicId,
    String? chapterId,
    Duration freshFor,
  ) async {
    try {
      final result = await source.loadComicPages!(comicId, chapterId);
      if (result.error) {
        return _StoredFetchResult(Res.fromErrorRes(result), false);
      }
      final normalizedChapterId = chapterId ?? '0';
      final payload = jsonEncode(result.data);
      final previousPayload = _readPayload(
        source.key,
        comicId,
        normalizedChapterId,
      );
      final changed = previousPayload != payload;
      _saveCache(
        source.key,
        comicId,
        normalizedChapterId,
        result.data,
        freshFor,
        payload: payload,
      );
      return _StoredFetchResult(Res(result.data), changed);
    } catch (e, s) {
      Log.error(
        'ChapterPagesRepository',
        'Failed to fetch pages for ${source.key}@$comicId#${chapterId ?? '0'}: $e',
        s,
      );
      return _StoredFetchResult(Res.error(e.toString()), false);
    }
  }

  _CachedChapterPages? _findCache(
    String sourceKey,
    String comicId,
    String chapterId,
  ) {
    final result = _db!.select(
      '''
      SELECT payload, updated_at, fresh_until
      FROM chapter_pages_cache
      WHERE source_key = ? AND comic_id = ? AND chapter_id = ?;
      ''',
      [sourceKey, comicId, chapterId],
    );
    if (result.isEmpty) {
      return null;
    }
    try {
      final row = result.first;
      final pages = List<String>.from(jsonDecode(row['payload'] as String));
      return _CachedChapterPages(
        pages,
        DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
        DateTime.fromMillisecondsSinceEpoch(row['fresh_until'] as int),
        row['payload'] as String,
      );
    } catch (e, s) {
      Log.error(
        'ChapterPagesRepository',
        'Failed to parse cached pages for $sourceKey@$comicId#$chapterId: $e',
        s,
      );
      _db!.execute(
        '''
        DELETE FROM chapter_pages_cache
        WHERE source_key = ? AND comic_id = ? AND chapter_id = ?;
        ''',
        [sourceKey, comicId, chapterId],
      );
      return null;
    }
  }

  void _saveCache(
    String sourceKey,
    String comicId,
    String chapterId,
    List<String> pages,
    Duration freshFor, {
    String? payload,
  }) {
    final now = DateTime.now();
    payload ??= jsonEncode(pages);
    _db!.execute(
      '''
      INSERT OR REPLACE INTO chapter_pages_cache (
        source_key,
        comic_id,
        chapter_id,
        payload,
        updated_at,
        fresh_until
      ) VALUES (?, ?, ?, ?, ?, ?);
      ''',
      [
        sourceKey,
        comicId,
        chapterId,
        payload,
        now.millisecondsSinceEpoch,
        now.add(freshFor).millisecondsSinceEpoch,
      ],
    );
  }

  String? _readPayload(String sourceKey, String comicId, String chapterId) {
    final result = _db!.select(
      '''
      SELECT payload
      FROM chapter_pages_cache
      WHERE source_key = ? AND comic_id = ? AND chapter_id = ?;
      ''',
      [sourceKey, comicId, chapterId],
    );
    if (result.isEmpty) {
      return null;
    }
    return result.first['payload'] as String;
  }

  void _scheduleBackgroundRefresh(
    String key,
    ComicSource source,
    String comicId,
    String? chapterId,
    Duration freshFor,
    String cachedPayload,
    FutureOr<void> Function(List<String> pages)? onBackgroundUpdate,
  ) {
    if (_backgroundRefreshTasks.containsKey(key)) {
      return;
    }
    _backgroundRefreshTasks[key] = Future(() async {
      try {
        final result = await _fetchAndStore(
          source,
          comicId,
          chapterId,
          freshFor,
        );
        if (result.result.success) {
          final normalizedChapterId = chapterId ?? '0';
          if (result.changed) {
            _logBackgroundRefresh(
              'chapter pages background refresh changed',
              source.key,
              comicId,
              normalizedChapterId,
            );
            if (onBackgroundUpdate != null) {
              await onBackgroundUpdate(result.result.data);
            }
          } else if (cachedPayload.isNotEmpty) {
            _logBackgroundRefresh(
              'chapter pages background refresh skipped',
              source.key,
              comicId,
              normalizedChapterId,
            );
          }
        }
      } catch (e, s) {
        Log.error(
          'ChapterPagesRepository',
          'Background refresh failed for $key: $e',
          s,
        );
      } finally {
        _backgroundRefreshTasks.remove(key);
      }
    });
  }

  String _buildKey(String sourceKey, String comicId, String chapterId) =>
      '$sourceKey@$comicId#$chapterId';

  void _logPerf(
    String label,
    Stopwatch stopwatch, {
    required String sourceKey,
    required String comicId,
    required String chapterId,
  }) {
    if (!kDebugMode) {
      return;
    }
    Log.info(
      'ChapterPagesRepository',
      '[perf] $label ${stopwatch.elapsedMilliseconds}ms $sourceKey@$comicId#$chapterId',
    );
  }

  void _logBackgroundRefresh(
    String label,
    String sourceKey,
    String comicId,
    String chapterId,
  ) {
    if (!kDebugMode) {
      return;
    }
    Log.info(
      'ChapterPagesRepository',
      '[perf] $label $sourceKey@$comicId#$chapterId',
    );
  }

  @visibleForTesting
  void debugReset() {
    _db?.dispose();
    _db = null;
    _initFuture = null;
    _backgroundRefreshTasks.clear();
  }
}

class _CachedChapterPages {
  const _CachedChapterPages(
    this.pages,
    this.updatedAt,
    this.freshUntil,
    this.payload,
  );

  final List<String> pages;
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
