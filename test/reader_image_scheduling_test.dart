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
        priority: ReaderImageLoadPriority.sameChapterPrefetch,
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

  test(
    'same-chapter prefetch cancels active next-chapter prefetch before starting',
    () async {
      final starts = <String>[];
      final nextChapterCancelled = Completer<void>();
      StreamController<ImageDownloadProgress>? nextChapterController;

      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) {
            starts.add(imageKey);
            if (imageKey == 'next-chapter') {
              nextChapterController = StreamController<ImageDownloadProgress>(
                onCancel: () async {
                  if (!nextChapterCancelled.isCompleted) {
                    nextChapterCancelled.complete();
                  }
                  await nextChapterController?.close();
                },
              );
              return nextChapterController!.stream;
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

      ImageDownloader.prefetchReaderImage(
        'next-chapter',
        'source',
        'cid',
        'eid',
        priority: ReaderImageLoadPriority.nextChapterPrefetch,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      ImageDownloader.prefetchReaderImage(
        'same-chapter',
        'source',
        'cid',
        'eid',
        priority: ReaderImageLoadPriority.sameChapterPrefetch,
      );

      await expectLater(
        nextChapterCancelled.future.timeout(const Duration(seconds: 1)),
        completes,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(starts, ['next-chapter', 'same-chapter']);
    },
  );

  test(
    'foreground promotion keeps an active load from later prefetch cancellation',
    () async {
      final targetCancelled = Completer<void>();
      final starts = <String>[];
      StreamController<ImageDownloadProgress>? targetController;

      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) {
            starts.add(imageKey);
            if (imageKey == 'target') {
              targetController = StreamController<ImageDownloadProgress>(
                onCancel: () async {
                  if (!targetCancelled.isCompleted) {
                    targetCancelled.complete();
                  }
                  await targetController?.close();
                },
              );
              return targetController!.stream;
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

      final prefetch = ImageDownloader.loadComicImage(
        'target',
        'source',
        'cid',
        'eid',
        priority: ReaderImageLoadPriority.sameChapterPrefetch,
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final visible = ImageDownloader.loadComicImage(
        'target',
        'source',
        'cid',
        'eid',
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final otherVisible = ImageDownloader.loadComicImage(
        'other-visible',
        'source',
        'cid',
        'eid',
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(starts, ['target', 'other-visible']);
      expect(targetCancelled.isCompleted, isFalse);

      await Future.wait([
        prefetch.cancel(),
        visible.cancel(),
        otherVisible.cancel(),
      ]);
    },
  );

  test(
    'foreground request cancels upstream once last listener leaves',
    () async {
      final cancelled = Completer<void>();
      StreamController<ImageDownloadProgress>? controller;

      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) {
            controller = StreamController<ImageDownloadProgress>(
              onCancel: () async {
                if (!cancelled.isCompleted) {
                  cancelled.complete();
                }
                await controller?.close();
              },
            );
            return controller!.stream;
          };

      final sub = ImageDownloader.loadComicImage(
        'visible',
        'source',
        'cid',
        'eid',
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await sub.cancel();

      await expectLater(
        cancelled.future.timeout(const Duration(seconds: 1)),
        completes,
      );
    },
  );

  test(
    'same-key request after foreground cancellation creates a fresh stream',
    () async {
      final starts = <String>[];
      StreamController<ImageDownloadProgress>? controller;

      ImageDownloader.debugReaderImageLoader =
          (
            String imageKey,
            String? sourceKey,
            String cid,
            String eid, {
            bool useCache = true,
          }) {
            starts.add(imageKey);
            controller = StreamController<ImageDownloadProgress>(
              onCancel: () async {
                await controller?.close();
              },
            );
            return controller!.stream;
          };

      final first = ImageDownloader.loadComicImage(
        'visible',
        'source',
        'cid',
        'eid',
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await first.cancel();

      final second = ImageDownloader.loadComicImage(
        'visible',
        'source',
        'cid',
        'eid',
      ).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(starts, ['visible', 'visible']);
      await second.cancel();
    },
  );
}
