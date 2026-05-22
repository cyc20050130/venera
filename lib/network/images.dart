import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/utils/image.dart';

import 'app_dio.dart';

abstract class ImageDownloader {
  static const _kReaderPrefetchPollInterval = Duration(milliseconds: 50);
  static const _kMaxConcurrentReaderPrefetches = 1;

  static final _readerImagePriorities = <String, _ReaderImageLoadPriority>{};
  static final _pendingReaderPrefetchRequests = <String>{};
  static final _activeReaderImageKinds = <String, _ReaderImageLoadPriority>{};

  static int _activeReaderForegroundLoads = 0;
  static int _activeReaderPrefetchLoads = 0;

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
    final prefetchKeys = <String>[];
    for (final entry in _loadingImages.entries) {
      final priority =
          _activeReaderImageKinds[entry.key] ??
          _readerImagePriorities[entry.key];
      if (priority == _ReaderImageLoadPriority.prefetch) {
        entry.value.cancel();
        prefetchKeys.add(entry.key);
      }
    }
    for (final key in prefetchKeys) {
      _loadingImages.remove(key);
      _readerImagePriorities.remove(key);
      _activeReaderImageKinds.remove(key);
      _pendingReaderPrefetchRequests.remove(key);
    }
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final requestedPriority = _pendingReaderPrefetchRequests.remove(cacheKey)
        ? _ReaderImageLoadPriority.prefetch
        : _ReaderImageLoadPriority.foreground;
    if (requestedPriority == _ReaderImageLoadPriority.foreground ||
        !_readerImagePriorities.containsKey(cacheKey)) {
      _readerImagePriorities[cacheKey] = requestedPriority;
    }
    if (_loadingImages.containsKey(cacheKey)) {
      _readerImagePriorities[cacheKey] = _ReaderImageLoadPriority.foreground;
      return _loadingImages[cacheKey]!.stream;
    }
    final cancelToken = CancelToken();
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _createReaderImageLoad(
        imageKey,
        sourceKey,
        cid,
        eid,
        cancelToken: cancelToken,
      ),
      (wrapper) {
        _loadingImages.remove(cacheKey);
        _readerImagePriorities.remove(cacheKey);
        _activeReaderImageKinds.remove(cacheKey);
      },
      beforeListen: () => _waitForReaderImageTurn(cacheKey),
      onListenStart: () => _markReaderImageStarted(cacheKey),
      onListenFinish: () => _markReaderImageFinished(cacheKey),
      onCancel: () => cancelToken.cancel('reader image request cancelled'),
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static void prefetchReaderImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    markReaderImagePrefetch(imageKey, sourceKey, cid, eid);
    if (_loadingImages.containsKey(cacheKey)) {
      return;
    }
    final cancelToken = CancelToken();
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _createReaderImageLoad(
        imageKey,
        sourceKey,
        cid,
        eid,
        cancelToken: cancelToken,
      ),
      (wrapper) {
        _loadingImages.remove(cacheKey);
        _readerImagePriorities.remove(cacheKey);
        _activeReaderImageKinds.remove(cacheKey);
      },
      beforeListen: () => _waitForReaderImageTurn(cacheKey),
      onListenStart: () => _markReaderImageStarted(cacheKey),
      onListenFinish: () => _markReaderImageFinished(cacheKey),
      onCancel: () => cancelToken.cancel('reader image request cancelled'),
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

  static void markReaderImagePrefetch(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    _pendingReaderPrefetchRequests.add(cacheKey);
    _readerImagePriorities.putIfAbsent(
      cacheKey,
      () => _ReaderImageLoadPriority.prefetch,
    );
  }

  static Stream<ImageDownloadProgress> _createReaderImageLoad(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    CancelToken? cancelToken,
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
    );
  }

  static Future<void> _waitForReaderImageTurn(String cacheKey) async {
    while (true) {
      final priority = _readerImagePriorities[cacheKey];
      if (priority == null ||
          priority == _ReaderImageLoadPriority.foreground ||
          (_activeReaderForegroundLoads == 0 &&
              _activeReaderPrefetchLoads < _kMaxConcurrentReaderPrefetches)) {
        return;
      }
      await Future.delayed(_kReaderPrefetchPollInterval);
    }
  }

  static void _markReaderImageStarted(String cacheKey) {
    final priority =
        _readerImagePriorities[cacheKey] ?? _ReaderImageLoadPriority.foreground;
    _activeReaderImageKinds[cacheKey] = priority;
    if (priority == _ReaderImageLoadPriority.foreground) {
      _activeReaderForegroundLoads++;
    } else {
      _activeReaderPrefetchLoads++;
    }
  }

  static void _markReaderImageFinished(String cacheKey) {
    final priority = _activeReaderImageKinds.remove(cacheKey);
    if (priority == _ReaderImageLoadPriority.foreground) {
      _activeReaderForegroundLoads--;
    } else if (priority == _ReaderImageLoadPriority.prefetch) {
      _activeReaderPrefetchLoads--;
    }
    if (_activeReaderForegroundLoads < 0) {
      _activeReaderForegroundLoads = 0;
    }
    if (_activeReaderPrefetchLoads < 0) {
      _activeReaderPrefetchLoads = 0;
    }
  }

  static void _resetReaderImageSchedulingState({
    bool resetDebugLoader = false,
  }) {
    _readerImagePriorities.clear();
    _pendingReaderPrefetchRequests.clear();
    _activeReaderImageKinds.clear();
    _activeReaderForegroundLoads = 0;
    _activeReaderPrefetchLoads = 0;
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
  }) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    if (useCache) {
      final cache = await CacheManager().findCache(cacheKey);
      if (cache != null) {
        var data = await cache.readAsBytes();
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
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

  StreamIterator<T>? _iterator;

  bool isClosed = false;

  _StreamWrapper(
    this._stream,
    this.onClosed, {
    this.beforeListen,
    this.onListenStart,
    this.onListenFinish,
    this.onCancel,
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

enum _ReaderImageLoadPriority { foreground, prefetch }

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
