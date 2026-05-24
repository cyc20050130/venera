import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
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
}
