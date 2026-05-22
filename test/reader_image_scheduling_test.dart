import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/images.dart';

void main() {
  setUp(() {
    ImageDownloader.debugResetReaderImageScheduling();
  });

  tearDown(() {
    ImageDownloader.debugResetReaderImageScheduling();
  });

  test('prefetch waits until active foreground reader loads finish', () async {
    final starts = <String>[];
    final foregroundRelease = Completer<void>();

    ImageDownloader.debugReaderImageLoader =
        (
          String imageKey,
          String? sourceKey,
          String cid,
          String eid, {
          bool useCache = true,
        }) async* {
          starts.add(imageKey);
          if (imageKey == 'foreground') {
            await foregroundRelease.future;
          }
          yield const ImageDownloadProgress(
            currentBytes: 1,
            totalBytes: 1,
            imageBytes: null,
          );
          yield ImageDownloadProgress(
            currentBytes: 1,
            totalBytes: 1,
            imageBytes: Uint8List.fromList([1]),
          );
        };

    final sub = ImageDownloader.loadComicImage(
      'foreground',
      'source',
      'cid',
      'eid',
    ).listen((_) {});

    await Future<void>.delayed(const Duration(milliseconds: 20));
    ImageDownloader.prefetchReaderImage('prefetch', 'source', 'cid', 'eid');
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(starts, ['foreground']);

    foregroundRelease.complete();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(starts, ['foreground', 'prefetch']);
    await sub.cancel();
  });

  test('foreground requests promote queued prefetches immediately', () async {
    final starts = <String>[];
    final blockerRelease = Completer<void>();

    ImageDownloader.debugReaderImageLoader =
        (
          String imageKey,
          String? sourceKey,
          String cid,
          String eid, {
          bool useCache = true,
        }) async* {
          starts.add(imageKey);
          if (imageKey == 'blocker') {
            await blockerRelease.future;
          }
          yield const ImageDownloadProgress(
            currentBytes: 1,
            totalBytes: 1,
            imageBytes: null,
          );
          yield ImageDownloadProgress(
            currentBytes: 1,
            totalBytes: 1,
            imageBytes: Uint8List.fromList([1]),
          );
        };

    final blocker = ImageDownloader.loadComicImage(
      'blocker',
      'source',
      'cid',
      'eid',
    ).listen((_) {});

    await Future<void>.delayed(const Duration(milliseconds: 20));
    ImageDownloader.prefetchReaderImage('target', 'source', 'cid', 'eid');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(starts, ['blocker']);

    final visible = ImageDownloader.loadComicImage(
      'target',
      'source',
      'cid',
      'eid',
    ).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(starts, ['blocker', 'target']);

    blockerRelease.complete();
    await Future.wait([blocker.cancel(), visible.cancel()]);
  });

  test(
    'marked precache requests also wait behind active foreground loads',
    () async {
      final starts = <String>[];
      final foregroundRelease = Completer<void>();

      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) async* {
            starts.add(imageKey);
            if (imageKey == 'foreground') {
              await foregroundRelease.future;
            }
            yield const ImageDownloadProgress(
              currentBytes: 1,
              totalBytes: 1,
              imageBytes: null,
            );
            yield ImageDownloadProgress(
              currentBytes: 1,
              totalBytes: 1,
              imageBytes: Uint8List.fromList([1]),
            );
          };

      final sub = ImageDownloader.loadComicImage(
        'foreground',
        'source',
        'cid',
        'eid',
      ).listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 20));
      ImageDownloader.markReaderImagePrefetch(
        'adjacent',
        'source',
        'cid',
        'eid',
      );
      final adjacent = ImageDownloader.loadComicImage(
        'adjacent',
        'source',
        'cid',
        'eid',
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(starts, ['foreground']);

      foregroundRelease.complete();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(starts, ['foreground', 'adjacent']);
      await Future.wait([sub.cancel(), adjacent.cancel()]);
    },
  );

  test('cancelAllLoadingImages resets reader scheduling state', () async {
    final starts = <String>[];
    final foregroundRelease = Completer<void>();

    ImageDownloader.debugReaderImageLoader =
        (
          String imageKey,
          String? sourceKey,
          String cid,
          String eid, {
          bool useCache = true,
        }) async* {
          starts.add(imageKey);
          if (imageKey == 'foreground') {
            await foregroundRelease.future;
          }
          yield const ImageDownloadProgress(
            currentBytes: 1,
            totalBytes: 1,
            imageBytes: null,
          );
          yield ImageDownloadProgress(
            currentBytes: 1,
            totalBytes: 1,
            imageBytes: Uint8List.fromList([1]),
          );
        };

    final sub = ImageDownloader.loadComicImage(
      'foreground',
      'source',
      'cid',
      'eid',
    ).listen((_) {});

    await Future<void>.delayed(const Duration(milliseconds: 20));
    ImageDownloader.markReaderImagePrefetch('prefetch', 'source', 'cid', 'eid');
    ImageDownloader.cancelAllLoadingImages();

    final fresh = ImageDownloader.loadComicImage(
      'fresh',
      'source',
      'cid',
      'eid',
    ).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(starts, ['foreground', 'fresh']);

    foregroundRelease.complete();
    await Future.wait([sub.cancel(), fresh.cancel()]);
  });

  test(
    'cancelReaderPrefetches drops queued prefetch without touching foreground',
    () async {
      final starts = <String>[];
      final foregroundRelease = Completer<void>();

      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) async* {
            starts.add(imageKey);
            if (imageKey == 'foreground') {
              await foregroundRelease.future;
            }
            yield const ImageDownloadProgress(
              currentBytes: 1,
              totalBytes: 1,
              imageBytes: null,
            );
            yield ImageDownloadProgress(
              currentBytes: 1,
              totalBytes: 1,
              imageBytes: Uint8List.fromList([1]),
            );
          };

      final sub = ImageDownloader.loadComicImage(
        'foreground',
        'source',
        'cid',
        'eid',
      ).listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 20));
      ImageDownloader.prefetchReaderImage('prefetch', 'source', 'cid', 'eid');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      ImageDownloader.cancelReaderPrefetches();

      foregroundRelease.complete();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(starts, ['foreground']);
      await sub.cancel();
    },
  );

  test('cancelReaderPrefetches cancels started prefetch streams', () async {
    final starts = <String>[];
    final prefetchCancelled = Completer<void>();
    StreamController<ImageDownloadProgress>? prefetchController;

    ImageDownloader.debugReaderImageLoader =
        (
          String imageKey,
          String? sourceKey,
          String cid,
          String eid, {
          bool useCache = true,
        }) {
          starts.add(imageKey);
          if (imageKey == 'prefetch') {
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
              imageBytes: Uint8List.fromList([1]),
            ),
          ]);
        };

    ImageDownloader.prefetchReaderImage('prefetch', 'source', 'cid', 'eid');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    ImageDownloader.cancelReaderPrefetches();

    await expectLater(
      prefetchCancelled.future.timeout(const Duration(seconds: 1)),
      completes,
    );
    expect(starts, ['prefetch']);
  });
}
