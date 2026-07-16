import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

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
  static int thumbnailLoadingCount = 0;

  static const _kMaxThumbnailLoadingCount = 8;
  static const _kMaxBackgroundThumbnailLoadingCount = 6;
  static const _kMaxConsecutiveForegroundThumbnailSlots = 8;
  static const _kThumbnailLoadingSlotPollInterval = Duration(milliseconds: 16);

  static final ListQueue<_ThumbnailLoadingSlotRequest>
  _pendingThumbnailLoadingSlots = ListQueue();
  static int _nextThumbnailLoadingSlotSequence = 0;
  static int _activeBackgroundThumbnailLoadingCount = 0;
  static int _activeForegroundThumbnailLoadingCount = 0;
  static int _consecutiveForegroundThumbnailSlots = 0;

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
  static Completer<void>? _readerSchedulerSignal;

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

  static int get debugMaxThumbnailLoadingCount => _kMaxThumbnailLoadingCount;

  static int get debugMaxBackgroundThumbnailLoadingCount =>
      _kMaxBackgroundThumbnailLoadingCount;

  static int get debugMaxConsecutiveForegroundThumbnailSlots =>
      _kMaxConsecutiveForegroundThumbnailSlots;

  static void debugResetThumbnailLoadingState() {
    _resetThumbnailLoadingState(resetDebugLoader: true);
  }

  static Future<void> debugAcquireThumbnailLoadingSlot(
    void Function() checkStop, {
    ThumbnailLoadPriority priority = ThumbnailLoadPriority.foregroundVisible,
  }) {
    return _acquireThumbnailLoadingSlot(checkStop, priority: priority);
  }

  static void debugReleaseThumbnailLoadingSlot({
    ThumbnailLoadPriority priority = ThumbnailLoadPriority.foregroundVisible,
  }) {
    _releaseThumbnailLoadingSlot(priority);
  }

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
    ThumbnailLoadPriority priority = ThumbnailLoadPriority.foregroundVisible,
    void Function()? checkStop,
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

    yield* _thumbnailRefreshStream(
      cacheKey,
      url,
      sourceKey,
      cid,
      priority,
      checkStop ?? () {},
    );
  }

  static Stream<ImageDownloadProgress> _thumbnailRefreshStream(
    String cacheKey,
    String url,
    String? sourceKey,
    String? cid,
    ThumbnailLoadPriority priority,
    void Function() checkStop,
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
      _loadThumbnailRefresh(cacheKey, url, sourceKey, cid, priority, checkStop),
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
    ThumbnailLoadPriority priority,
    void Function() checkStop,
  ) async* {
    await _acquireThumbnailLoadingSlot(checkStop, priority: priority);
    try {
      yield* _loadThumbnailRefreshWithAcquiredSlot(
        cacheKey,
        url,
        sourceKey,
        cid,
        priority,
        checkStop,
        redirectCount: 0,
      );
    } finally {
      _releaseThumbnailLoadingSlot(priority);
    }
  }

  static Stream<ImageDownloadProgress> _loadThumbnailRefreshWithAcquiredSlot(
    String cacheKey,
    String url,
    String? sourceKey,
    String? cid,
    ThumbnailLoadPriority priority,
    void Function() checkStop, {
    required int redirectCount,
  }) async* {
    final cached = await _readNonEmptyImageCache(cacheKey);
    if (cached != null) {
      yield ImageDownloadProgress(
        currentBytes: cached.length,
        totalBytes: cached.length,
        imageBytes: cached,
      );
      return;
    }

    final debugLoader = debugThumbnailNetworkLoader;
    if (debugLoader != null) {
      Uint8List? imageBytes;
      await for (final progress in debugLoader(url, sourceKey, cid)) {
        checkStop();
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
        if (redirectCount > 0) {
          throw "Too many cover fallback redirects.";
        }
        var comicInfo = await loadComicInfo(comicId);
        if (comicInfo.error) {
          throw comicInfo.errorMessage ?? "Failed to load comic cover";
        }
        final redirectCacheKey = "${comicInfo.data.cover}@$sourceKey@$comicId";
        yield* _loadThumbnailRefreshWithAcquiredSlot(
          redirectCacheKey,
          comicInfo.data.cover,
          sourceKey,
          comicId,
          priority,
          checkStop,
          redirectCount: redirectCount + 1,
        );
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
    final cancelToken = CancelToken();
    Timer? stopPoller;
    try {
      checkStop();
      stopPoller = Timer.periodic(_kThumbnailLoadingSlotPollInterval, (_) {
        try {
          checkStop();
        } catch (_) {
          cancelToken.cancel('thumbnail request cancelled');
        }
      });
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
      final buffer = BytesBuilder(copy: false);
      await for (var data in stream) {
        checkStop();
        buffer.add(data);
        if (expectedBytes != null) {
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }
      }

      List<int> imageBytes = buffer.takeBytes();

      if (configs['onResponse'] is JSInvokable) {
        final onResponse = configs['onResponse'] as JSInvokable;
        final processedBytes = await runImageOnResponseCallback(
          () => onResponse([_asUint8List(imageBytes)]),
          release: onResponse.free,
          label: 'thumbnail',
        );
        if (processedBytes != null) {
          imageBytes = processedBytes;
        } else {
          Log.warning(
            "Network",
            "Ignoring invalid thumbnail onResponse result",
          );
        }
      }

      if (imageBytes.isEmpty) {
        throw "Error: Empty response body.";
      }
      final resultBytes = _asUint8List(imageBytes);
      _logThumbnailPerf('cover network complete', cacheKey);
      await _writeThumbnailCache(cacheKey, resultBytes);
      yield ImageDownloadProgress(
        currentBytes: resultBytes.length,
        totalBytes: resultBytes.length,
        imageBytes: resultBytes,
      );
    } finally {
      stopPoller?.cancel();
    }
  }

  static Future<void> _acquireThumbnailLoadingSlot(
    void Function() checkStop, {
    required ThumbnailLoadPriority priority,
  }) async {
    final waiter = Completer<void>();
    final request = _ThumbnailLoadingSlotRequest(
      waiter: waiter,
      priority: priority,
      sequence: _nextThumbnailLoadingSlotSequence++,
    );
    var acquired = false;
    _pendingThumbnailLoadingSlots.add(request);
    try {
      while (true) {
        _drainThumbnailLoadingQueue();
        if (waiter.isCompleted) {
          acquired = true;
          return;
        }
        await Future.any([
          waiter.future,
          Future<void>.delayed(_kThumbnailLoadingSlotPollInterval),
        ]);
        checkStop();
      }
    } catch (_) {
      if (!acquired) {
        if (!_pendingThumbnailLoadingSlots.remove(request) &&
            waiter.isCompleted) {
          _releaseThumbnailLoadingSlot(priority);
        }
      }
      rethrow;
    }
  }

  static void _releaseThumbnailLoadingSlot(ThumbnailLoadPriority priority) {
    if (thumbnailLoadingCount > 0) {
      thumbnailLoadingCount--;
    }
    if (priority == ThumbnailLoadPriority.background &&
        _activeBackgroundThumbnailLoadingCount > 0) {
      _activeBackgroundThumbnailLoadingCount--;
    }
    if (priority == ThumbnailLoadPriority.foregroundVisible &&
        _activeForegroundThumbnailLoadingCount > 0) {
      _activeForegroundThumbnailLoadingCount--;
    }
    _drainThumbnailLoadingQueue();
  }

  static void _drainThumbnailLoadingQueue() {
    while (thumbnailLoadingCount < _kMaxThumbnailLoadingCount &&
        _pendingThumbnailLoadingSlots.isNotEmpty) {
      final request = _removeNextThumbnailLoadingRequest();
      if (request == null) {
        break;
      }
      thumbnailLoadingCount++;
      if (request.priority == ThumbnailLoadPriority.background) {
        _activeBackgroundThumbnailLoadingCount++;
        _consecutiveForegroundThumbnailSlots = 0;
      } else {
        _activeForegroundThumbnailLoadingCount++;
        _consecutiveForegroundThumbnailSlots++;
      }
      request.waiter.complete();
    }
  }

  static _ThumbnailLoadingSlotRequest? _removeNextThumbnailLoadingRequest() {
    _ThumbnailLoadingSlotRequest? best;
    for (final request in _pendingThumbnailLoadingSlots) {
      if (!_canAcquireThumbnailLoadingSlot(request.priority)) {
        continue;
      }
      if (_shouldReserveNextSlotForBackground(request.priority)) {
        continue;
      }
      if (best == null ||
          request.priority.index > best.priority.index ||
          (request.priority.index == best.priority.index &&
              request.sequence < best.sequence)) {
        best = request;
      }
    }
    if (best == null) {
      return null;
    }
    _pendingThumbnailLoadingSlots.remove(best);
    return best.waiter.isCompleted ? null : best;
  }

  static bool _canAcquireThumbnailLoadingSlot(ThumbnailLoadPriority priority) {
    if (thumbnailLoadingCount >= _kMaxThumbnailLoadingCount) {
      return false;
    }
    if (priority == ThumbnailLoadPriority.background &&
        _activeBackgroundThumbnailLoadingCount >=
            _kMaxBackgroundThumbnailLoadingCount) {
      return false;
    }
    return true;
  }

  static bool _shouldReserveNextSlotForBackground(
    ThumbnailLoadPriority priority,
  ) {
    if (priority != ThumbnailLoadPriority.foregroundVisible ||
        _consecutiveForegroundThumbnailSlots <
            _kMaxConsecutiveForegroundThumbnailSlots) {
      return false;
    }
    return _pendingThumbnailLoadingSlots.any(
      (request) =>
          request.priority == ThumbnailLoadPriority.background &&
          _canAcquireThumbnailLoadingSlot(ThumbnailLoadPriority.background),
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
      _notifyReaderScheduler();
    }
    final existing = _loadingImages[cacheKey];
    if (existing != null) {
      if (existing.isClosed) {
        _finishReaderImageLoad(cacheKey);
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
    late final _StreamWrapper<ImageDownloadProgress> stream;
    stream = _StreamWrapper<ImageDownloadProgress>(
      _createReaderImageLoad(
        imageKey,
        sourceKey,
        cid,
        eid,
        cancelToken: cancelToken,
        cacheStrategy: cacheStrategy,
      ),
      (wrapper) {
        if (_loadingImages[cacheKey] == wrapper) {
          _removeReaderImageLoadState(cacheKey);
        }
      },
      beforeListen: () async {
        if (requestedPriority == ReaderImageLoadPriority.foregroundVisible) {
          _cancelReaderLoadsWhere(
            (priority) => priority != ReaderImageLoadPriority.foregroundVisible,
            excludeCacheKey: cacheKey,
          );
        }
        await _acquireReaderImageTurn(
          cacheKey,
          isCurrent: () => _loadingImages[cacheKey] == stream,
        );
      },
      onListenFinish: (wrapper) {
        if (_loadingImages[cacheKey] == wrapper) {
          _markReaderImageFinished(cacheKey);
        }
      },
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
        _finishReaderImageLoad(cacheKey);
      } else {
        return;
      }
    }
    final cancelToken = CancelToken();
    late final _StreamWrapper<ImageDownloadProgress> stream;
    stream = _StreamWrapper<ImageDownloadProgress>(
      _createReaderImageLoad(
        imageKey,
        sourceKey,
        cid,
        eid,
        cancelToken: cancelToken,
        cacheStrategy: ComicImageCacheStrategy.cacheHitIsTerminal,
      ),
      (wrapper) {
        if (_loadingImages[cacheKey] == wrapper) {
          _removeReaderImageLoadState(cacheKey);
        }
      },
      beforeListen: () => _acquireReaderImageTurn(
        cacheKey,
        isCurrent: () => _loadingImages[cacheKey] == stream,
      ),
      onListenFinish: (wrapper) {
        if (_loadingImages[cacheKey] == wrapper) {
          _markReaderImageFinished(cacheKey);
        }
      },
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
    thumbnailLoadingCount = 0;
    _pendingThumbnailLoadingSlots.clear();
    _nextThumbnailLoadingSlotSequence = 0;
    _activeBackgroundThumbnailLoadingCount = 0;
    _activeForegroundThumbnailLoadingCount = 0;
    _consecutiveForegroundThumbnailSlots = 0;
    if (resetDebugLoader) {
      debugThumbnailNetworkLoader = null;
      debugThumbnailCacheWriter = null;
    }
  }

  @visibleForTesting
  static void debugSetReaderLifecycleQuietUntil(DateTime? quietUntil) {
    _readerLifecycleQuietUntil = quietUntil;
    _notifyReaderScheduler();
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
    _notifyReaderScheduler();
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
    _notifyReaderScheduler();
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

  static Future<void> _acquireReaderImageTurn(
    String cacheKey, {
    required bool Function() isCurrent,
  }) async {
    while (true) {
      if (!isCurrent()) {
        return;
      }
      final priority = _readerImagePriorities[cacheKey];
      if (priority == null) {
        return;
      }
      final quietRemaining =
          priority == ReaderImageLoadPriority.foregroundVisible
          ? Duration.zero
          : readerLifecycleQuietRemaining;
      final totalPrefetchLoads =
          _activeReaderSameChapterPrefetchLoads +
          _activeReaderNextChapterPrefetchLoads;
      final hasCompetingSameChapterWork =
          priority == ReaderImageLoadPriority.nextChapterPrefetch &&
          _hasQueuedOrActivePriority(
            ReaderImageLoadPriority.sameChapterPrefetch,
            excludeCacheKey: cacheKey,
          );
      final canStart =
          priority == ReaderImageLoadPriority.foregroundVisible ||
          (quietRemaining == Duration.zero &&
              _activeReaderForegroundLoads == 0 &&
              totalPrefetchLoads < _kMaxConcurrentReaderPrefetches &&
              !hasCompetingSameChapterWork);
      if (canStart) {
        _markReaderImageStarted(cacheKey);
        return;
      }
      final signal = _readerSchedulerSignal ??= Completer<void>();
      if (quietRemaining > Duration.zero) {
        await Future.any([signal.future, Future<void>.delayed(quietRemaining)]);
      } else {
        await signal.future;
      }
    }
  }

  static void _notifyReaderScheduler() {
    final signal = _readerSchedulerSignal;
    _readerSchedulerSignal = null;
    if (signal != null && !signal.isCompleted) {
      signal.complete();
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
    _notifyReaderScheduler();
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
    _notifyReaderScheduler();
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
        final buffer = BytesBuilder(copy: false);
        await for (var data in stream) {
          buffer.add(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        List<int> responseBytes = buffer.takeBytes();

        final rawOnResponse = configs['onResponse'];
        if (rawOnResponse is JSInvokable) {
          final processedBytes = await runImageOnResponseCallback(
            () => rawOnResponse([_asUint8List(responseBytes)]),
            release: rawOnResponse.free,
            label: 'reader',
          );
          if (processedBytes != null) {
            responseBytes = processedBytes;
          } else {
            Log.warning("Network", "Ignoring invalid reader onResponse result");
          }
        }

        var data = _asUint8List(responseBytes);

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
    var changed = false;
    final storedPriority = _readerImagePriorities[cacheKey];
    if (storedPriority == null || targetPriority.index < storedPriority.index) {
      _readerImagePriorities[cacheKey] = targetPriority;
      changed = true;
    }
    final activePriority = _activeReaderImageKinds[cacheKey];
    if (activePriority != null && targetPriority.index < activePriority.index) {
      _decrementActiveReaderLoadCount(activePriority);
      _activeReaderImageKinds[cacheKey] = targetPriority;
      _incrementActiveReaderLoadCount(targetPriority);
      changed = true;
    }
    if (changed) {
      _notifyReaderScheduler();
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
    _notifyReaderScheduler();
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

Uint8List _asUint8List(List<int> bytes) {
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;
  final Future<void> Function()? beforeListen;
  final void Function(_StreamWrapper<T> wrapper)? onListenFinish;
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
      onListenFinish?.call(this);
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

enum ThumbnailLoadPriority { background, foregroundVisible }

enum ReaderImageLoadPriority {
  foregroundVisible,
  sameChapterPrefetch,
  nextChapterPrefetch,
}

class _ThumbnailLoadingSlotRequest {
  const _ThumbnailLoadingSlotRequest({
    required this.waiter,
    required this.priority,
    required this.sequence,
  });

  final Completer<void> waiter;
  final ThumbnailLoadPriority priority;
  final int sequence;
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
