import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/image.dart';

import 'app_dio.dart';

@visibleForTesting
Map<String, dynamic> normalizeThumbnailLoadingConfig(Object? value) {
  return _normalizeImageLoadingConfig(value);
}

@visibleForTesting
Map<String, dynamic> normalizeComicImageLoadingConfig(Object? value) {
  return _normalizeImageLoadingConfig(value);
}

Map<String, dynamic> _normalizeImageLoadingConfig(Object? value) {
  final config = <String, dynamic>{};
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String) {
        config[key] = entry.value;
      }
    }
  }
  final headers = <String, dynamic>{};
  final rawHeaders = config['headers'];
  if (rawHeaders is Map) {
    for (final entry in rawHeaders.entries) {
      final key = entry.key;
      if (key is String) {
        headers[key] = entry.value;
      }
    }
  }
  config['headers'] = headers;
  if (config['url'] is! String) {
    config.remove('url');
  }
  if (config['method'] is! String) {
    config.remove('method');
  }
  return config;
}

@visibleForTesting
int? normalizeImageResponseContentLength(int? contentLength) {
  if (contentLength == null || contentLength < 0) {
    return null;
  }
  return contentLength;
}

@visibleForTesting
bool shouldRedirectThumbnailToComicCover({
  required String requestUrl,
  required String? sourceKey,
  required String? cid,
  required bool hasComicInfoLoader,
}) {
  return requestUrl.startsWith('cover.') &&
      sourceKey != null &&
      cid != null &&
      cid.isNotEmpty &&
      hasComicInfoLoader;
}

@visibleForTesting
List<int>? normalizeImageOnResponseBytes(Object? value) {
  if (value is Uint8List) {
    return value;
  }
  if (value is List<int>) {
    return value;
  }
  if (value is Iterable) {
    final bytes = value.whereType<int>().toList();
    return bytes.isEmpty ? null : bytes;
  }
  return null;
}

@visibleForTesting
Future<List<int>?> runImageOnResponseCallback(
  FutureOr<Object?> Function() callback, {
  void Function()? release,
  String label = 'image',
}) async {
  try {
    final result = await callback();
    return normalizeImageOnResponseBytes(result);
  } catch (e, s) {
    Log.warning("Network", "Ignoring failed $label onResponse: $e\n$s");
    return null;
  } finally {
    release?.call();
  }
}

abstract class ImageDownloader {
  static const _kReaderPrefetchPollInterval = Duration(milliseconds: 16);
  static const _kMaxConcurrentReaderPrefetches = 1;
  static const _kReaderLifecycleResumeQuietWindow = Duration(milliseconds: 900);

  static final _readerImagePriorities = <String, ReaderImageLoadPriority>{};
  static final _pendingReaderPrefetchRequests =
      <String, ReaderImageLoadPriority>{};
  static final _activeReaderImageKinds = <String, ReaderImageLoadPriority>{};
  static DateTime? _readerLifecycleQuietUntil;

  static int _activeReaderForegroundLoads = 0;
  static int _activeReaderSameChapterPrefetchLoads = 0;
  static int _activeReaderNextChapterPrefetchLoads = 0;

  @visibleForTesting
  static Stream<ImageDownloadProgress> Function(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    bool useCache,
  })?
  debugReaderImageLoader;

  @visibleForTesting
  static Stream<ImageDownloadProgress> Function(
    String url,
    String? sourceKey,
    String? cid,
  )?
  debugThumbnailNetworkLoader;

  @visibleForTesting
  static Future<void> Function(String cacheKey, List<int> data)?
  debugThumbnailCacheWriter;

  static final _loadingThumbnails =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final data = await _readNonEmptyImageCache(cacheKey);
    if (data != null) {
      _logThumbnailPerf('cover cache hit', cacheKey);
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      return;
    }

    yield* _thumbnailRefreshStream(cacheKey, url, sourceKey, cid);
  }

  static Stream<ImageDownloadProgress> _thumbnailRefreshStream(
    String cacheKey,
    String url,
    String? sourceKey,
    String? cid,
  ) {
    var existing = _loadingThumbnails[cacheKey];
    if (existing != null && existing.isClosed) {
      _loadingThumbnails.remove(cacheKey);
      existing = null;
    }
    if (existing != null) {
      return existing.stream;
    }

    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadThumbnailRefresh(cacheKey, url, sourceKey, cid),
      (wrapper) {
        if (_loadingThumbnails[cacheKey] == wrapper) {
          _loadingThumbnails.remove(cacheKey);
        }
      },
      replayLastValue: true,
    );
    _loadingThumbnails[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> _loadThumbnailRefresh(
    String cacheKey,
    String url,
    String? sourceKey,
    String? cid,
  ) async* {
    final debugLoader = debugThumbnailNetworkLoader;
    if (debugLoader != null) {
      Uint8List? imageBytes;
      await for (final progress in debugLoader(url, sourceKey, cid)) {
        if (progress.imageBytes != null) {
          imageBytes = progress.imageBytes;
        }
        yield progress;
      }
      if (imageBytes != null) {
        await _writeThumbnailCache(cacheKey, imageBytes);
      }
      return;
    }

    var configs = normalizeThumbnailLoadingConfig(null);
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = normalizeThumbnailLoadingConfig(
        comicSource?.getThumbnailLoadingConfig?.call(url),
      );
    }
    final headers = configs['headers'] as Map<String, dynamic>;
    if (headers['user-agent'] == null && headers['User-Agent'] == null) {
      headers['user-agent'] = webUA;
    }

    final requestUrlFromConfig = (configs['url'] as String?) ?? url;
    if (requestUrlFromConfig.startsWith('cover.') && sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      final loadComicInfo = comicSource?.loadComicInfo;
      final comicId = cid;
      if (shouldRedirectThumbnailToComicCover(
            requestUrl: requestUrlFromConfig,
            sourceKey: sourceKey,
            cid: comicId,
            hasComicInfoLoader: loadComicInfo != null,
          ) &&
          loadComicInfo != null &&
          comicId != null) {
        var comicInfo = await loadComicInfo(comicId);
        if (comicInfo.error) {
          throw comicInfo.errorMessage ?? "Failed to load comic cover";
        }
        yield* loadThumbnail(comicInfo.data.cover, sourceKey, comicId);
        return;
      }
      Log.warning(
        "Network",
        "Skip thumbnail cover redirect without comic id or loader: $sourceKey",
      );
      configs.remove('url');
    }

    var dio = AppDio(
      BaseOptions(
        headers: headers,
        method: configs['method'] as String? ?? 'GET',
        responseType: ResponseType.stream,
      ),
    );

    String requestUrl = configs['url'] as String? ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(
      requestUrl,
      data: configs['data'],
    );
    final body = req.data ?? (throw "Error: Empty response body.");
    var stream = body.stream;
    final expectedBytes = normalizeImageResponseContentLength(
      body.contentLength,
    );
    var buffer = <int>[];
    await for (var data in stream) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    if (configs['onResponse'] is JSInvokable) {
      final uint8List = Uint8List.fromList(buffer);
      final onResponse = configs['onResponse'] as JSInvokable;
      final processedBytes = await runImageOnResponseCallback(
        () => onResponse([uint8List]),
        release: onResponse.free,
        label: 'thumbnail',
      );
      if (processedBytes != null) {
        buffer = processedBytes;
      } else {
        Log.warning("Network", "Ignoring invalid thumbnail onResponse result");
      }
    }

    if (buffer.isEmpty) {
      throw "Error: Empty response body.";
    }
    _logThumbnailPerf('cover network complete', cacheKey);
    await _writeThumbnailCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static Future<void> _writeThumbnailCache(
    String cacheKey,
    List<int> data,
  ) async {
    if (data.isEmpty) {
      Log.warning("Image Cache", "Skip empty thumbnail cache: $cacheKey");
      return;
    }
    final writer = debugThumbnailCacheWriter;
    if (writer != null) {
      await writer(cacheKey, data);
      return;
    }
    _logThumbnailPerf('cover write cache', cacheKey);
    await CacheManager().writeCache(cacheKey, data);
  }

  static Future<Uint8List?> _readNonEmptyImageCache(String cacheKey) async {
    final cache = await CacheManager().findCache(cacheKey);
    if (cache == null) {
      return null;
    }
    final data = await cache.readAsBytes();
    if (data.isNotEmpty) {
      return data;
    }
    Log.warning("Image Cache", "Discard empty cache entry: $cacheKey");
    await CacheManager().delete(cacheKey);
    return null;
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values) {
      wrapper.cancel();
    }
    _loadingImages.clear();
    _resetReaderImageSchedulingState();
  }

  static void cancelReaderPrefetches() {
    _cancelReaderLoadsWhere(
      (priority) => priority != ReaderImageLoadPriority.foregroundVisible,
    );
  }

  static void markReaderLifecyclePaused() {
    _readerLifecycleQuietUntil = null;
    cancelReaderPrefetches();
  }

  static void markReaderLifecycleResumed({
    DateTime? now,
    Duration quietWindow = _kReaderLifecycleResumeQuietWindow,
  }) {
    final currentTime = now ?? DateTime.now();
    _readerLifecycleQuietUntil = currentTime.add(quietWindow);
    cancelReaderPrefetches();
  }

  static Duration get readerLifecycleQuietRemaining {
    final quietUntil = _readerLifecycleQuietUntil;
    if (quietUntil == null) {
      return Duration.zero;
    }
    final remaining = quietUntil.difference(DateTime.now());
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  static bool get isReaderLifecycleQuiet =>
      readerLifecycleQuietRemaining > Duration.zero;

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageCacheStrategy cacheStrategy =
        ComicImageCacheStrategy.cacheHitThenRefresh,
    ReaderImageLoadPriority priority =
        ReaderImageLoadPriority.foregroundVisible,
  }) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    _pendingReaderPrefetchRequests.remove(cacheKey);
    final requestedPriority = priority;
    if (requestedPriority == ReaderImageLoadPriority.foregroundVisible &&
        cacheStrategy == ComicImageCacheStrategy.cacheHitIsTerminal) {
      final data = await _readNonEmptyImageCache(cacheKey);
      if (data != null) {
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        _logReaderImagePerf('reader image cache hit terminal', cacheKey);
        return;
      }
    }
    if (requestedPriority == ReaderImageLoadPriority.sameChapterPrefetch) {
      _cancelReaderLoadsWhere(
        (priority) => priority == ReaderImageLoadPriority.nextChapterPrefetch,
        excludeCacheKey: cacheKey,
      );
    }
    if (requestedPriority == ReaderImageLoadPriority.foregroundVisible ||
        !_readerImagePriorities.containsKey(cacheKey)) {
      _readerImagePriorities[cacheKey] = requestedPriority;
    }
    final existing = _loadingImages[cacheKey];
    if (existing != null) {
      if (existing.isClosed) {
        _removeReaderImageLoadState(cacheKey);
      } else {
        if (requestedPriority == ReaderImageLoadPriority.foregroundVisible) {
          _promoteReaderImageLoad(
            cacheKey,
            ReaderImageLoadPriority.foregroundVisible,
          );
          _cancelReaderLoadsWhere(
            (priority) => priority != ReaderImageLoadPriority.foregroundVisible,
            excludeCacheKey: cacheKey,
          );
        }
        yield* existing.stream;
        return;
      }
    }
    final cancelToken = CancelToken();
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _createReaderImageLoad(
        imageKey,
        sourceKey,
        cid,
        eid,
        cancelToken: cancelToken,
        cacheStrategy: cacheStrategy,
      ),
      (wrapper) => _removeReaderImageLoadState(cacheKey),
      beforeListen: () async {
        if (requestedPriority == ReaderImageLoadPriority.foregroundVisible) {
          _cancelReaderLoadsWhere(
            (priority) => priority != ReaderImageLoadPriority.foregroundVisible,
            excludeCacheKey: cacheKey,
          );
        }
        await _waitForReaderImageTurn(cacheKey);
      },
      onListenStart: () => _markReaderImageStarted(cacheKey),
      onListenFinish: () => _markReaderImageFinished(cacheKey),
      onCancel: () => cancelToken.cancel('reader image request cancelled'),
      keepAliveWithoutListeners:
          requestedPriority != ReaderImageLoadPriority.foregroundVisible,
      onNoListeners: () {
        _logReaderImagePerf('reader image cancelled no listeners', cacheKey);
      },
    );
    _loadingImages[cacheKey] = stream;
    yield* stream.stream;
  }

  static void prefetchReaderImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ReaderImageLoadPriority priority =
        ReaderImageLoadPriority.sameChapterPrefetch,
  }) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    markReaderImagePrefetch(imageKey, sourceKey, cid, eid, priority: priority);
    if (priority == ReaderImageLoadPriority.sameChapterPrefetch) {
      _cancelReaderLoadsWhere(
        (currentPriority) =>
            currentPriority == ReaderImageLoadPriority.nextChapterPrefetch,
        excludeCacheKey: cacheKey,
      );
    }
    final existing = _loadingImages[cacheKey];
    if (existing != null) {
      if (existing.isClosed) {
        _removeReaderImageLoadState(cacheKey);
      } else {
        return;
      }
    }
    final cancelToken = CancelToken();
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _createReaderImageLoad(
        imageKey,
        sourceKey,
        cid,
        eid,
        cancelToken: cancelToken,
        cacheStrategy: ComicImageCacheStrategy.cacheHitIsTerminal,
      ),
      (wrapper) => _removeReaderImageLoadState(cacheKey),
      beforeListen: () => _waitForReaderImageTurn(cacheKey),
      onListenStart: () => _markReaderImageStarted(cacheKey),
      onListenFinish: () => _markReaderImageFinished(cacheKey),
      onCancel: () => cancelToken.cancel('reader image request cancelled'),
      keepAliveWithoutListeners: true,
    );
    _loadingImages[cacheKey] = stream;
    stream.stream.listen((_) {}, onError: (_) {});
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return _loadComicImage(imageKey, sourceKey, cid, eid);
  }

  /// Download a comic image without reading from or writing to runtime cache.
  ///
  /// Used by offline download tasks so background downloads do not contend with
  /// reader cache maintenance or duplicate writes.
  static Stream<ImageDownloadProgress> loadComicImageNoCache(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final loader = debugReaderImageLoader;
    if (loader != null) {
      return loader(imageKey, sourceKey, cid, eid, useCache: false);
    }
    return _loadComicImage(imageKey, sourceKey, cid, eid, useCache: false);
  }

  @visibleForTesting
  static void debugResetReaderImageScheduling() {
    _resetThumbnailLoadingState(resetDebugLoader: true);
    _resetReaderImageSchedulingState(resetDebugLoader: true);
  }

  static void _resetThumbnailLoadingState({bool resetDebugLoader = false}) {
    for (final wrapper in _loadingThumbnails.values) {
      wrapper.cancel();
    }
    _loadingThumbnails.clear();
    if (resetDebugLoader) {
      debugThumbnailNetworkLoader = null;
      debugThumbnailCacheWriter = null;
    }
  }

  @visibleForTesting
  static void debugSetReaderLifecycleQuietUntil(DateTime? quietUntil) {
    _readerLifecycleQuietUntil = quietUntil;
  }

  @visibleForTesting
  static bool shouldDeferReaderImageLoadForLifecycle(
    ReaderImageLoadPriority priority, {
    DateTime? now,
  }) {
    if (priority == ReaderImageLoadPriority.foregroundVisible) {
      return false;
    }
    final quietUntil = _readerLifecycleQuietUntil;
    if (quietUntil == null) {
      return false;
    }
    return quietUntil.isAfter(now ?? DateTime.now());
  }

  static bool hasQueuedOrActiveReaderLoad(ReaderImageLoadPriority priority) {
    return _hasQueuedOrActivePriority(priority);
  }

  static void markReaderImageVisible(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    _pendingReaderPrefetchRequests.remove(cacheKey);
    _promoteReaderImageLoad(
      cacheKey,
      ReaderImageLoadPriority.foregroundVisible,
    );
  }

  static void markReaderImagePrefetch(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ReaderImageLoadPriority priority =
        ReaderImageLoadPriority.sameChapterPrefetch,
  }) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final existingPriority = _pendingReaderPrefetchRequests[cacheKey];
    if (existingPriority == null || priority.index < existingPriority.index) {
      _pendingReaderPrefetchRequests[cacheKey] = priority;
    }
    final activePriority = _readerImagePriorities[cacheKey];
    if (activePriority == null || priority.index < activePriority.index) {
      _readerImagePriorities[cacheKey] = priority;
    }
  }

  static Stream<ImageDownloadProgress> _createReaderImageLoad(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    CancelToken? cancelToken,
    ComicImageCacheStrategy cacheStrategy =
        ComicImageCacheStrategy.cacheHitIsTerminal,
  }) {
    final loader = debugReaderImageLoader;
    if (loader != null) {
      return loader(imageKey, sourceKey, cid, eid, useCache: true);
    }
    return _loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      cancelToken: cancelToken,
      cacheStrategy: cacheStrategy,
    );
  }

  static Future<void> _waitForReaderImageTurn(String cacheKey) async {
    while (true) {
      final priority = _readerImagePriorities[cacheKey];
      if (priority == null ||
          priority == ReaderImageLoadPriority.foregroundVisible) {
        return;
      }
      if (shouldDeferReaderImageLoadForLifecycle(priority)) {
        await Future.delayed(_kReaderPrefetchPollInterval);
        continue;
      }
      final totalPrefetchLoads =
          _activeReaderSameChapterPrefetchLoads +
          _activeReaderNextChapterPrefetchLoads;
      final hasCompetingSameChapterWork =
          priority == ReaderImageLoadPriority.nextChapterPrefetch &&
          _hasQueuedOrActivePriority(
            ReaderImageLoadPriority.sameChapterPrefetch,
            excludeCacheKey: cacheKey,
          );
      if (_activeReaderForegroundLoads == 0 &&
          totalPrefetchLoads < _kMaxConcurrentReaderPrefetches &&
          !hasCompetingSameChapterWork) {
        return;
      }
      await Future.delayed(_kReaderPrefetchPollInterval);
    }
  }

  static void _markReaderImageStarted(String cacheKey) {
    final priority =
        _readerImagePriorities[cacheKey] ??
        ReaderImageLoadPriority.foregroundVisible;
    _activeReaderImageKinds[cacheKey] = priority;
    _incrementActiveReaderLoadCount(priority);
    if (priority == ReaderImageLoadPriority.foregroundVisible) {
      _logReaderImagePerf('reader image cache miss network', cacheKey);
    } else if (priority == ReaderImageLoadPriority.sameChapterPrefetch) {
      _logReaderImagePerf('reader same chapter prefetch start', cacheKey);
    } else {
      _logReaderImagePerf('reader next chapter prefetch start', cacheKey);
    }
  }

  static void _markReaderImageFinished(String cacheKey) {
    final priority = _activeReaderImageKinds.remove(cacheKey);
    _decrementActiveReaderLoadCount(priority);
  }

  static void _resetReaderImageSchedulingState({
    bool resetDebugLoader = false,
  }) {
    _readerImagePriorities.clear();
    _pendingReaderPrefetchRequests.clear();
    _activeReaderImageKinds.clear();
    _activeReaderForegroundLoads = 0;
    _activeReaderSameChapterPrefetchLoads = 0;
    _activeReaderNextChapterPrefetchLoads = 0;
    _readerLifecycleQuietUntil = null;
    if (resetDebugLoader) {
      debugReaderImageLoader = null;
    }
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    bool useCache = true,
    CancelToken? cancelToken,
    ComicImageCacheStrategy cacheStrategy =
        ComicImageCacheStrategy.cacheHitThenRefresh,
  }) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    if (useCache && cacheStrategy != ComicImageCacheStrategy.networkOnly) {
      final data = await _readNonEmptyImageCache(cacheKey);
      if (data != null) {
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        if (cacheStrategy == ComicImageCacheStrategy.cacheHitIsTerminal) {
          _logReaderImagePerf('reader image cache hit terminal', cacheKey);
          return;
        }
      }
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = normalizeComicImageLoadingConfig(null);
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = normalizeComicImageLoadingConfig(
        await comicSource?.getImageLoadingConfig?.call(imageKey, cid, eid),
      );
    }
    var retryLimit = 5;
    while (true) {
      JSInvokable? onLoadFailedInvokable;
      try {
        final headers = configs['headers'] as Map<String, dynamic>;
        if (headers['user-agent'] == null && headers['User-Agent'] == null) {
          headers['user-agent'] = webUA;
        }

        final rawOnLoadFailed = configs['onLoadFailed'];
        if (rawOnLoadFailed is JSInvokable) {
          onLoadFailedInvokable = rawOnLoadFailed;
          onLoadFailed = () async {
            dynamic result = rawOnLoadFailed([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map) return null;
            return normalizeComicImageLoadingConfig(result);
          };
        }

        var dio = AppDio(
          BaseOptions(
            headers: headers,
            method: configs['method'] as String? ?? 'GET',
            responseType: ResponseType.stream,
          ),
        );

        String requestUrl = configs['url'] as String? ?? imageKey;
        if (requestUrl.startsWith('//')) {
          requestUrl = 'https:$requestUrl';
        }
        var req = await dio.request<ResponseBody>(
          requestUrl,
          data: configs['data'],
          cancelToken: cancelToken,
        );
        final body = req.data ?? (throw "Error: Empty response body.");
        var stream = body.stream;
        final expectedBytes = normalizeImageResponseContentLength(
          body.contentLength,
        );
        var buffer = <int>[];
        await for (var data in stream) {
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        final rawOnResponse = configs['onResponse'];
        if (rawOnResponse is JSInvokable) {
          final processedBytes = await runImageOnResponseCallback(
            () => rawOnResponse([Uint8List.fromList(buffer)]),
            release: rawOnResponse.free,
            label: 'reader',
          );
          if (processedBytes != null) {
            buffer = processedBytes;
          } else {
            Log.warning("Network", "Ignoring invalid reader onResponse result");
          }
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        if (data.isEmpty) {
          throw "Error: Empty response body.";
        }
        if (useCache) {
          await CacheManager().writeCache(cacheKey, data);
        }
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        Map<String, dynamic>? newConfig;
        try {
          newConfig = await onLoadFailed();
        } finally {
          onLoadFailedInvokable?.free();
          onLoadFailedInvokable = null;
          onLoadFailed = null;
        }
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        onLoadFailedInvokable?.free();
        onLoadFailed = null;
      }
    }
  }

  static bool _hasQueuedOrActivePriority(
    ReaderImageLoadPriority priority, {
    String? excludeCacheKey,
  }) {
    for (final entry in _readerImagePriorities.entries) {
      if (entry.key == excludeCacheKey) {
        continue;
      }
      if (entry.value == priority) {
        return true;
      }
    }
    for (final entry in _pendingReaderPrefetchRequests.entries) {
      if (entry.key == excludeCacheKey) {
        continue;
      }
      if (entry.value == priority) {
        return true;
      }
    }
    for (final entry in _activeReaderImageKinds.entries) {
      if (entry.key == excludeCacheKey) {
        continue;
      }
      if (entry.value == priority) {
        return true;
      }
    }
    return false;
  }

  static void _promoteReaderImageLoad(
    String cacheKey,
    ReaderImageLoadPriority targetPriority,
  ) {
    final storedPriority = _readerImagePriorities[cacheKey];
    if (storedPriority == null || targetPriority.index < storedPriority.index) {
      _readerImagePriorities[cacheKey] = targetPriority;
    }
    final activePriority = _activeReaderImageKinds[cacheKey];
    if (activePriority != null && targetPriority.index < activePriority.index) {
      _decrementActiveReaderLoadCount(activePriority);
      _activeReaderImageKinds[cacheKey] = targetPriority;
      _incrementActiveReaderLoadCount(targetPriority);
    }
  }

  static void _incrementActiveReaderLoadCount(
    ReaderImageLoadPriority priority,
  ) {
    switch (priority) {
      case ReaderImageLoadPriority.foregroundVisible:
        _activeReaderForegroundLoads++;
      case ReaderImageLoadPriority.sameChapterPrefetch:
        _activeReaderSameChapterPrefetchLoads++;
      case ReaderImageLoadPriority.nextChapterPrefetch:
        _activeReaderNextChapterPrefetchLoads++;
    }
  }

  static void _decrementActiveReaderLoadCount(
    ReaderImageLoadPriority? priority,
  ) {
    switch (priority) {
      case ReaderImageLoadPriority.foregroundVisible:
        _activeReaderForegroundLoads--;
      case ReaderImageLoadPriority.sameChapterPrefetch:
        _activeReaderSameChapterPrefetchLoads--;
      case ReaderImageLoadPriority.nextChapterPrefetch:
        _activeReaderNextChapterPrefetchLoads--;
      case null:
        break;
    }
    if (_activeReaderForegroundLoads < 0) {
      _activeReaderForegroundLoads = 0;
    }
    if (_activeReaderSameChapterPrefetchLoads < 0) {
      _activeReaderSameChapterPrefetchLoads = 0;
    }
    if (_activeReaderNextChapterPrefetchLoads < 0) {
      _activeReaderNextChapterPrefetchLoads = 0;
    }
  }

  static void _cancelReaderLoadsWhere(
    bool Function(ReaderImageLoadPriority priority) predicate, {
    String? excludeCacheKey,
  }) {
    final keysToCancel = <String>[];
    for (final entry in _loadingImages.entries) {
      if (entry.key == excludeCacheKey) {
        continue;
      }
      final priority =
          _activeReaderImageKinds[entry.key] ??
          _readerImagePriorities[entry.key] ??
          _pendingReaderPrefetchRequests[entry.key];
      if (priority != null && predicate(priority)) {
        entry.value.cancel();
        keysToCancel.add(entry.key);
      }
    }
    for (final key in keysToCancel) {
      _finishReaderImageLoad(key);
    }
  }

  static void _removeReaderImageLoadState(String cacheKey) {
    _loadingImages.remove(cacheKey);
    _readerImagePriorities.remove(cacheKey);
    _activeReaderImageKinds.remove(cacheKey);
    _pendingReaderPrefetchRequests.remove(cacheKey);
  }

  static void _finishReaderImageLoad(String cacheKey) {
    final priority = _activeReaderImageKinds.remove(cacheKey);
    _decrementActiveReaderLoadCount(priority);
    _removeReaderImageLoadState(cacheKey);
  }

  static void _logReaderImagePerf(String label, String cacheKey) {
    if (!kDebugMode) {
      return;
    }
    Log.info('ImageDownloader', '[perf] $label $cacheKey');
  }

  static void _logThumbnailPerf(String label, String cacheKey) {
    if (!kDebugMode) {
      return;
    }
    Log.info('ImageDownloader', '[perf] $label $cacheKey');
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;
  final Future<void> Function()? beforeListen;
  final void Function()? onListenStart;
  final void Function()? onListenFinish;
  final void Function()? onCancel;
  final void Function()? onNoListeners;
  final bool keepAliveWithoutListeners;
  final bool replayLastValue;

  StreamIterator<T>? _iterator;
  T? _lastValue;
  bool _hasLastValue = false;

  bool isClosed = false;
  bool _isListening = false;

  _StreamWrapper(
    this._stream,
    this.onClosed, {
    this.beforeListen,
    this.onListenStart,
    this.onListenFinish,
    this.onCancel,
    this.onNoListeners,
    this.keepAliveWithoutListeners = false,
    this.replayLastValue = false,
  });

  void _listen() async {
    try {
      await beforeListen?.call();
      if (isClosed) {
        return;
      }
      onListenStart?.call();
      _iterator = StreamIterator(_stream);
      while (!isClosed && await _iterator!.moveNext()) {
        final data = _iterator!.current;
        if (replayLastValue) {
          _lastValue = data;
          _hasLastValue = true;
        }
        if (isClosed) {
          break;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    } catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    } finally {
      try {
        await _iterator?.cancel();
      } catch (e, s) {
        Log.error(
          "ImageDownloader",
          "Failed to cancel shared image stream: $e",
          s,
        );
      }
      _iterator = null;
      onListenFinish?.call();
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    if (replayLastValue && _hasLastValue) {
      controller.add(_lastValue as T);
    }
    if (!_isListening) {
      _isListening = true;
      _listen();
    }
    controller.onCancel = () {
      controllers.remove(controller);
      if (controllers.isEmpty && !keepAliveWithoutListeners && !isClosed) {
        onNoListeners?.call();
        cancel();
      }
    };
    return controller.stream;
  }

  void cancel() {
    if (isClosed) {
      return;
    }
    onCancel?.call();
    for (var controller in controllers) {
      controller.close();
    }
    controllers.clear();
    isClosed = true;
    unawaited(
      (_iterator?.cancel() ?? Future.value()).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        Log.error(
          "ImageDownloader",
          "Failed to cancel shared image stream: $error",
          stackTrace,
        );
      }),
    );
  }
}

enum ComicImageCacheStrategy {
  cacheHitIsTerminal,
  cacheHitThenRefresh,
  networkOnly,
}

enum ReaderImageLoadPriority {
  foregroundVisible,
  sameChapterPrefetch,
  nextChapterPrefetch,
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
