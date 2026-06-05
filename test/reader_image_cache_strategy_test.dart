import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/images.dart';

import 'test_native_paths.dart';

void main() {
  late Directory tempDir;
  late Directory tempCacheDir;
  late HttpServer server;
  late Uri imageUri;
  late Uri slowImageUri;
  int requestCount = 0;

  setUpAll(() {
    open.overrideFor(OperatingSystem.windows, openTestSqlite);
  });

  setUp(() async {
    ImageDownloader.debugResetReaderImageScheduling();
    tempDir = await Directory.systemTemp.createTemp('venera-reader-image-');
    tempCacheDir = await Directory.systemTemp.createTemp(
      'venera-reader-image-cache-',
    );
    App.dataPath = tempDir.path;
    App.cachePath = tempCacheDir.path;
    CacheManager.instance?.close();
    requestCount = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    imageUri = Uri.parse(
      'http://${server.address.host}:${server.port}/image.bin',
    );
    slowImageUri = Uri.parse(
      'http://${server.address.host}:${server.port}/slow.bin',
    );
    server.listen((request) async {
      requestCount++;
      if (request.uri.path == '/slow.bin') {
        await Future<void>.delayed(const Duration(seconds: 1));
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.binary
          ..add([5, 4, 3, 2]);
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.binary
        ..add([9, 8, 7, 6]);
      await request.response.close();
    });
  });

  tearDown(() async {
    ImageDownloader.debugResetReaderImageScheduling();
    await server.close(force: true);
    CacheManager.instance?.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    if (await tempCacheDir.exists()) {
      await tempCacheDir.delete(recursive: true);
    }
  });

  test(
    'reader cache-hit terminal strategy returns cached bytes without network',
    () async {
      final cacheKey = '${imageUri.toString()}@null@cid@eid';
      await CacheManager().writeCache(cacheKey, [1, 2, 3, 4]);

      final events = await ImageDownloader.loadComicImage(
        imageUri.toString(),
        null,
        'cid',
        'eid',
        cacheStrategy: ComicImageCacheStrategy.cacheHitIsTerminal,
      ).toList();

      expect(requestCount, 0);
      expect(events, hasLength(1));
      expect(events.single.imageBytes, [1, 2, 3, 4]);
    },
  );

  test(
    'reader cache-hit terminal strategy refreshes empty cache entries',
    () async {
      final cacheKey = '${imageUri.toString()}@null@cid@eid';
      await CacheManager().writeCache(cacheKey, const []);
      var loaderCalls = 0;
      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) {
            loaderCalls++;
            return Stream<ImageDownloadProgress>.fromIterable([
              ImageDownloadProgress(
                currentBytes: 4,
                totalBytes: 4,
                imageBytes: Uint8List.fromList([9, 8, 7, 6]),
              ),
            ]);
          };

      final events = await ImageDownloader.loadComicImage(
        imageUri.toString(),
        null,
        'cid',
        'eid',
        cacheStrategy: ComicImageCacheStrategy.cacheHitIsTerminal,
      ).toList();

      expect(requestCount, 0);
      expect(loaderCalls, 1);
      expect(events.last.imageBytes, [9, 8, 7, 6]);
      expect(await CacheManager().findCache(cacheKey), isNull);
    },
  );

  test(
    'terminal cache-hit visible load does not cancel active same-chapter prefetch',
    () async {
      final visibleCacheKey = '${imageUri.toString()}@null@cid@eid';
      final prefetchCancelled = Completer<void>();
      StreamController<ImageDownloadProgress>? prefetchController;
      await CacheManager().writeCache(visibleCacheKey, [1, 2, 3, 4]);

      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) {
            if (imageKey == slowImageUri.toString()) {
              prefetchController = StreamController<ImageDownloadProgress>(
                onCancel: () async {
                  if (!prefetchCancelled.isCompleted) {
                    prefetchCancelled.complete();
                  }
                  await prefetchController?.close();
                },
              );
              return prefetchController!.stream;
            }
            return Stream<ImageDownloadProgress>.fromIterable([
              const ImageDownloadProgress(
                currentBytes: 1,
                totalBytes: 1,
                imageBytes: null,
              ),
              ImageDownloadProgress(
                currentBytes: 1,
                totalBytes: 1,
                imageBytes: Uint8List.fromList([9, 8, 7, 6]),
              ),
            ]);
          };

      final prefetch = ImageDownloader.loadComicImage(
        slowImageUri.toString(),
        null,
        'cid',
        'prefetch-eid',
        priority: ReaderImageLoadPriority.sameChapterPrefetch,
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final events = await ImageDownloader.loadComicImage(
        imageUri.toString(),
        null,
        'cid',
        'eid',
        cacheStrategy: ComicImageCacheStrategy.cacheHitIsTerminal,
      ).toList();

      expect(events, hasLength(1));
      expect(events.single.imageBytes, [1, 2, 3, 4]);
      expect(prefetchCancelled.isCompleted, isFalse);
      await prefetch.cancel();
      ImageDownloader.cancelReaderPrefetches();
      await expectLater(
        prefetchCancelled.future.timeout(const Duration(seconds: 1)),
        completes,
      );
    },
  );

  test('thumbnail refresh is shared for the same cache key', () async {
    var networkCalls = 0;
    var cacheWrites = 0;
    final releaseNetwork = Completer<void>();

    ImageDownloader.debugThumbnailNetworkLoader = (url, sourceKey, cid) async* {
      networkCalls++;
      yield const ImageDownloadProgress(currentBytes: 1, totalBytes: 4);
      await releaseNetwork.future;
      yield ImageDownloadProgress(
        currentBytes: 4,
        totalBytes: 4,
        imageBytes: Uint8List.fromList([4, 3, 2, 1]),
      );
    };
    ImageDownloader.debugThumbnailCacheWriter = (cacheKey, data) async {
      cacheWrites++;
      await CacheManager().writeCache(cacheKey, data);
    };

    final first = ImageDownloader.loadThumbnail(
      'https://example.com/thumb.jpg',
      null,
      'cid',
    ).toList();
    await Future<void>.delayed(Duration.zero);
    final second = ImageDownloader.loadThumbnail(
      'https://example.com/thumb.jpg',
      null,
      'cid',
    ).toList();
    await Future<void>.delayed(Duration.zero);

    expect(networkCalls, 1);
    releaseNetwork.complete();

    final firstEvents = await first;
    final secondEvents = await second;

    expect(networkCalls, 1);
    expect(cacheWrites, 1);
    expect(firstEvents.last.imageBytes, [4, 3, 2, 1]);
    expect(secondEvents.last.imageBytes, [4, 3, 2, 1]);

    final cached = await CacheManager().findCache(
      'https://example.com/thumb.jpg@null@cid',
    );
    expect(cached, isNotNull);
    expect(await cached!.readAsBytes(), [4, 3, 2, 1]);
  });

  test('thumbnail cache ignores empty entries and refreshes', () async {
    final cacheKey = 'https://example.com/empty-thumb.jpg@null@cid';
    await CacheManager().writeCache(cacheKey, const []);
    var networkCalls = 0;
    ImageDownloader.debugThumbnailNetworkLoader = (url, sourceKey, cid) async* {
      networkCalls++;
      yield ImageDownloadProgress(
        currentBytes: 2,
        totalBytes: 2,
        imageBytes: Uint8List.fromList([2, 1]),
      );
    };

    final events = await ImageDownloader.loadThumbnail(
      'https://example.com/empty-thumb.jpg',
      null,
      'cid',
    ).toList();

    expect(networkCalls, 1);
    expect(events, hasLength(1));
    expect(events.single.imageBytes, [2, 1]);
    final cached = await CacheManager().findCache(cacheKey);
    expect(cached, isNotNull);
    expect(await cached!.readAsBytes(), [2, 1]);
  });

  test('thumbnail refresh skips writing empty image bytes', () async {
    var cacheWrites = 0;
    ImageDownloader.debugThumbnailNetworkLoader = (url, sourceKey, cid) async* {
      yield ImageDownloadProgress(
        currentBytes: 0,
        totalBytes: 0,
        imageBytes: Uint8List(0),
      );
    };
    ImageDownloader.debugThumbnailCacheWriter = (cacheKey, data) async {
      cacheWrites++;
    };

    final events = await ImageDownloader.loadThumbnail(
      'https://example.com/empty-result.jpg',
      null,
      'cid',
    ).toList();

    expect(events.single.imageBytes, isEmpty);
    expect(cacheWrites, 0);
  });

  test('thumbnail loading config normalizes malformed source values', () {
    final config = normalizeThumbnailLoadingConfig({
      'url': 1,
      'method': 2,
      'headers': {'Accept': 'image/*', 1: 'ignored'},
      'data': [1, 2],
    });

    expect(config.containsKey('url'), isFalse);
    expect(config.containsKey('method'), isFalse);
    expect(config['headers'], {'Accept': 'image/*'});
    expect(config['data'], [1, 2]);

    expect(normalizeThumbnailLoadingConfig(null)['headers'], isEmpty);
  });

  test('comic image loading config normalizes malformed source values', () {
    final config = normalizeComicImageLoadingConfig({
      'url': 1,
      'method': false,
      'headers': {'Referer': 'https://example.com', 2: 'ignored'},
      'data': {'keep': true},
    });

    expect(config.containsKey('url'), isFalse);
    expect(config.containsKey('method'), isFalse);
    expect(config['headers'], {'Referer': 'https://example.com'});
    expect(config['data'], {'keep': true});

    expect(normalizeComicImageLoadingConfig('bad')['headers'], isEmpty);
  });

  test(
    'parser image loading config result tolerates non-map source values',
    () {
      expect(normalizeImageLoadingConfigResult('bad'), isEmpty);
      expect(
        normalizeImageLoadingConfigResult({
          'url': 'https://example.com/image.jpg',
          1: 'ignored',
          'headers': {'Accept': 'image/*'},
        }),
        {
          'url': 'https://example.com/image.jpg',
          'headers': {'Accept': 'image/*'},
        },
      );
    },
  );

  test('image response content length normalizes missing values', () {
    expect(normalizeImageResponseContentLength(4), 4);
    expect(normalizeImageResponseContentLength(0), 0);
    expect(normalizeImageResponseContentLength(null), isNull);
    expect(normalizeImageResponseContentLength(-1), isNull);
  });

  test('image onResponse bytes normalizes malformed callback results', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    expect(identical(normalizeImageOnResponseBytes(bytes), bytes), isTrue);
    expect(normalizeImageOnResponseBytes([1, 2, 3]), [1, 2, 3]);
    expect(normalizeImageOnResponseBytes([1, 'bad', 3]), [1, 3]);
    expect(normalizeImageOnResponseBytes(['bad']), isNull);
    expect(normalizeImageOnResponseBytes('bad'), isNull);
    expect(normalizeImageOnResponseBytes(null), isNull);
  });

  test(
    'image onResponse callback failures release resources and continue',
    () async {
      var released = 0;

      expect(
        await runImageOnResponseCallback(
          () => [1, 2, 3],
          release: () {
            released++;
          },
        ),
        [1, 2, 3],
      );
      expect(released, 1);

      expect(
        await runImageOnResponseCallback(
          () async => [4, 5, 6],
          release: () {
            released++;
          },
        ),
        [4, 5, 6],
      );
      expect(released, 2);

      expect(
        await runImageOnResponseCallback(
          () => throw StateError('bad callback'),
          release: () {
            released++;
          },
        ),
        isNull,
      );
      expect(released, 3);
    },
  );

  test(
    'thumbnail cache hit returns immediately without background refresh',
    () async {
      const cacheKey = 'https://example.com/thumb-hit.jpg@null@cid';
      await CacheManager().writeCache(cacheKey, [1, 1, 1, 1]);

      var networkCalls = 0;
      var cacheWrites = 0;
      ImageDownloader.debugThumbnailNetworkLoader =
          (url, sourceKey, cid) async* {
            networkCalls++;
            yield ImageDownloadProgress(
              currentBytes: 4,
              totalBytes: 4,
              imageBytes: Uint8List.fromList([2, 2, 2, 2]),
            );
          };
      ImageDownloader.debugThumbnailCacheWriter = (cacheKey, data) async {
        cacheWrites++;
        await CacheManager().writeCache(cacheKey, data);
      };

      final first = ImageDownloader.loadThumbnail(
        'https://example.com/thumb-hit.jpg',
        null,
        'cid',
      ).toList();
      await Future<void>.delayed(Duration.zero);
      final second = ImageDownloader.loadThumbnail(
        'https://example.com/thumb-hit.jpg',
        null,
        'cid',
      ).toList();
      await Future<void>.delayed(Duration.zero);

      final firstEvents = await first;
      final secondEvents = await second;

      expect(networkCalls, 0);
      expect(cacheWrites, 0);
      expect(firstEvents, hasLength(1));
      expect(secondEvents, hasLength(1));
      expect(firstEvents.single.imageBytes, [1, 1, 1, 1]);
      expect(secondEvents.single.imageBytes, [1, 1, 1, 1]);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(networkCalls, 0);
      expect(cacheWrites, 0);
      final cached = await CacheManager().findCache(cacheKey);
      expect(cached, isNotNull);
      expect(await cached!.readAsBytes(), [1, 1, 1, 1]);
    },
  );

  test(
    'distinct visible thumbnails are not throttled by a global queue',
    () async {
      final started = <String>[];
      final releaseNetwork = Completer<void>();
      ImageDownloader.debugThumbnailNetworkLoader =
          (url, sourceKey, cid) async* {
            started.add(url);
            yield const ImageDownloadProgress(currentBytes: 1, totalBytes: 4);
            await releaseNetwork.future;
            yield ImageDownloadProgress(
              currentBytes: 4,
              totalBytes: 4,
              imageBytes: Uint8List.fromList([url.hashCode & 0xff, 2, 2, 2]),
            );
          };

      final loads = List.generate(6, (index) {
        return ImageDownloader.loadThumbnail(
          'https://example.com/visible-$index.jpg',
          null,
          'cid-$index',
        ).toList();
      });
      await Future<void>.delayed(Duration.zero);

      expect(started, hasLength(6));

      releaseNetwork.complete();
      final events = await Future.wait(loads);
      expect(events, everyElement(isNotEmpty));
    },
  );

  test('thumbnail cover redirect requires comic id and info loader', () {
    expect(
      shouldRedirectThumbnailToComicCover(
        requestUrl: 'cover.redirect',
        sourceKey: 'source',
        cid: 'comic',
        hasComicInfoLoader: true,
      ),
      isTrue,
    );
    expect(
      shouldRedirectThumbnailToComicCover(
        requestUrl: 'cover.redirect',
        sourceKey: 'source',
        cid: null,
        hasComicInfoLoader: true,
      ),
      isFalse,
    );
    expect(
      shouldRedirectThumbnailToComicCover(
        requestUrl: 'cover.redirect',
        sourceKey: 'source',
        cid: 'comic',
        hasComicInfoLoader: false,
      ),
      isFalse,
    );
    expect(
      shouldRedirectThumbnailToComicCover(
        requestUrl: imageUri.toString(),
        sourceKey: 'source',
        cid: 'comic',
        hasComicInfoLoader: true,
      ),
      isFalse,
    );
  });
}
