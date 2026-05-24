import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/image.dart';

import 'app_dio.dart';

abstract class ImageDownloader {
  static const _kReaderPrefetchPollInterval = Duration(milliseconds: 16);
  static const _kMaxConcurrentReaderPrefetches = 1;

  static final _readerImagePriorities = <String, ReaderImageLoadPriority>{};
  static final _pendingReaderPrefetchRequests =
      <String, ReaderImageLoadPriority>{};
  static final _activeReaderImageKinds = <String, ReaderImageLoadPriority>{};

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

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* loadThumbnail(comicInfo.data.cover, sourceKey);
        return;
      }
    }

    var dio = AppDio(
      BaseOptions(
        headers: Map<String, dynamic>.from(configs['headers']),
        method: configs['method'] ?? 'GET',
        responseType: ResponseType.stream,
      ),
    );

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(
      requestUrl,
      data: configs['data'],
    );
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
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
      buffer = (configs['onResponse'] as JSInvokable)([uint8List]);
      (configs['onResponse'] as JSInvokable).free();
    }

    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
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
      final cache = await CacheManager().findCache(cacheKey);
      if (cache != null) {
        final data = await cache.readAsBytes();
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
    return _loadComicImage(imageKey, sourceKey, cid, eid, useCache: false);
  }

  @visibleForTesting
  static void debugResetReaderImageScheduling() {
    _resetReaderImageSchedulingState(resetDebugLoader: true);
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
      final cache = await CacheManager().findCache(cacheKey);
      if (cache != null) {
        var data = await cache.readAsBytes();
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

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs =
          (await comicSource!.getImageLoadingConfig?.call(
            imageKey,
            cid,
            eid,
          )) ??
          {};
    }
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {'user-agent': webUA};

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        var dio = AppDio(
          BaseOptions(
            headers: configs['headers'],
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
          ),
        );

        var req = await dio.request<ResponseBody>(
          configs['url'] ?? imageKey,
          data: configs['data'],
          cancelToken: cancelToken,
        );
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        var buffer = <int>[];
        await for (var data in stream) {
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        if (configs['onResponse'] is JSInvokable) {
          dynamic result = (configs['onResponse'] as JSInvokable)([
            Uint8List.fromList(buffer),
          ]);
          if (result is Future) {
            result = await result;
          }
          if (result is List<int>) {
            buffer = result;
          } else {
            throw "Error: Invalid onResponse result.";
          }
          (configs['onResponse'] as JSInvokable).free();
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
        var newConfig = await onLoadFailed();
        (configs['onLoadFailed'] as JSInvokable).free();
        onLoadFailed = null;
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
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
      _removeReaderImageLoadState(key);
    }
  }

  static void _removeReaderImageLoadState(String cacheKey) {
    _loadingImages.remove(cacheKey);
    _readerImagePriorities.remove(cacheKey);
    _activeReaderImageKinds.remove(cacheKey);
    _pendingReaderPrefetchRequests.remove(cacheKey);
  }

  static void _logReaderImagePerf(String label, String cacheKey) {
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

  StreamIterator<T>? _iterator;

  bool isClosed = false;

  _StreamWrapper(
    this._stream,
    this.onClosed, {
    this.beforeListen,
    this.onListenStart,
    this.onListenFinish,
    this.onCancel,
    this.onNoListeners,
    this.keepAliveWithoutListeners = false,
  }) {
    _listen();
  }

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
      await _iterator?.cancel();
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
    unawaited(_iterator?.cancel() ?? Future.value());
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
