import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'venera-thumbnail-scheduling-test-',
    );
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    CacheManager.instance?.close();
    ComicSourceManager().remove('thumbnail-test-source');
  });

  tearDown(() {
    CachedImageProvider.debugResetLoadingState();
  });

  tearDown(() async {
    ComicSourceManager().remove('thumbnail-test-source');
    CacheManager.instance?.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('thumbnail concurrency cap stays at the historical limit', () {
    expect(CachedImageProvider.debugMaxLoadingCount, 8);
  });

  test('cached image provider defaults to foreground-visible priority', () {
    final provider = CachedImageProvider('https://example.com/cover.jpg');

    expect(provider.loadPriority, ThumbnailLoadPriority.foregroundVisible);
  });

  test('cover loading acquires queued thumbnail slots in FIFO order', () async {
    final acquisitions = <int>[];
    CachedImageProvider.loadingCount = CachedImageProvider.debugMaxLoadingCount;

    final first = _acquireSlot(1, acquisitions);
    final second = _acquireSlot(2, acquisitions);
    final third = _acquireSlot(3, acquisitions);

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(acquisitions, isEmpty);

    CachedImageProvider.loadingCount =
        CachedImageProvider.debugMaxLoadingCount - 1;

    await first.timeout(const Duration(seconds: 1));
    expect(acquisitions, [1]);

    CachedImageProvider.debugReleaseLoadingSlot();
    await second.timeout(const Duration(seconds: 1));
    expect(acquisitions, [1, 2]);

    CachedImageProvider.debugReleaseLoadingSlot();
    await third.timeout(const Duration(seconds: 1));
    expect(acquisitions, [1, 2, 3]);

    CachedImageProvider.debugReleaseLoadingSlot();
    expect(
      CachedImageProvider.loadingCount,
      CachedImageProvider.debugMaxLoadingCount - 1,
    );
  });

  test(
    'visible cover loading can bypass queued background thumbnails',
    () async {
      final acquisitions = <int>[];
      CachedImageProvider.loadingCount =
          CachedImageProvider.debugMaxLoadingCount;

      final background1 = _acquireSlot(
        1,
        acquisitions,
        priority: ThumbnailLoadPriority.background,
      );
      final background2 = _acquireSlot(
        2,
        acquisitions,
        priority: ThumbnailLoadPriority.background,
      );
      final visible = _acquireSlot(
        3,
        acquisitions,
        priority: ThumbnailLoadPriority.foregroundVisible,
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(acquisitions, isEmpty);

      CachedImageProvider.loadingCount =
          CachedImageProvider.debugMaxLoadingCount - 1;

      await visible.timeout(const Duration(seconds: 1));
      expect(acquisitions, [3]);

      CachedImageProvider.debugReleaseLoadingSlot(
        priority: ThumbnailLoadPriority.foregroundVisible,
      );
      await background1.timeout(const Duration(seconds: 1));
      expect(acquisitions, [3, 1]);

      CachedImageProvider.debugReleaseLoadingSlot(
        priority: ThumbnailLoadPriority.background,
      );
      await background2.timeout(const Duration(seconds: 1));
      expect(acquisitions, [3, 1, 2]);

      CachedImageProvider.debugReleaseLoadingSlot(
        priority: ThumbnailLoadPriority.background,
      );
      expect(
        CachedImageProvider.loadingCount,
        CachedImageProvider.debugMaxLoadingCount - 1,
      );
    },
  );

  test(
    'cancelled cover loading waiter does not leak a thumbnail slot',
    () async {
      var stopCancelledLoad = false;
      CachedImageProvider.loadingCount =
          CachedImageProvider.debugMaxLoadingCount;

      final cancelledResult = CachedImageProvider.debugAcquireLoadingSlot(() {
        if (stopCancelledLoad) {
          throw _TestImageLoadingStopped();
        }
      });
      final waitingResult = CachedImageProvider.debugAcquireLoadingSlot(() {});

      stopCancelledLoad = true;
      await expectLater(
        cancelledResult.timeout(const Duration(seconds: 1)),
        throwsA(isA<_TestImageLoadingStopped>()),
      );
      expect(
        CachedImageProvider.loadingCount,
        CachedImageProvider.debugMaxLoadingCount,
      );

      CachedImageProvider.loadingCount =
          CachedImageProvider.debugMaxLoadingCount - 1;

      await waitingResult.timeout(const Duration(seconds: 1));
      CachedImageProvider.debugReleaseLoadingSlot();
      expect(
        CachedImageProvider.loadingCount,
        CachedImageProvider.debugMaxLoadingCount - 1,
      );
    },
  );

  test(
    'thumbnail loader prioritizes visible loads over download cover work',
    () async {
      final acquisitions = <String>[];
      ImageDownloader.debugResetThumbnailLoadingState();
      ImageDownloader.thumbnailLoadingCount =
          ImageDownloader.debugMaxThumbnailLoadingCount;

      final downloadCover = _acquireThumbnailSlot(
        'download-cover',
        acquisitions,
        priority: ThumbnailLoadPriority.background,
      );
      final historyCover = _acquireThumbnailSlot('history-cover', acquisitions);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(acquisitions, isEmpty);

      ImageDownloader.thumbnailLoadingCount =
          ImageDownloader.debugMaxThumbnailLoadingCount - 1;

      await historyCover.timeout(const Duration(seconds: 1));
      expect(acquisitions, ['history-cover']);

      ImageDownloader.debugReleaseThumbnailLoadingSlot();
      await downloadCover.timeout(const Duration(seconds: 1));
      expect(acquisitions, ['history-cover', 'download-cover']);

      ImageDownloader.debugReleaseThumbnailLoadingSlot(
        priority: ThumbnailLoadPriority.background,
      );
      expect(
        ImageDownloader.thumbnailLoadingCount,
        ImageDownloader.debugMaxThumbnailLoadingCount - 1,
      );
    },
  );

  test('download cover loading is classified as background thumbnail work', () {
    final downloadSource = File('lib/network/download.dart').readAsStringSync();

    expect(downloadSource, contains('ImageDownloader.loadThumbnail'));
    expect(downloadSource, contains('comicId'));
    expect(downloadSource, contains('ThumbnailLoadPriority.background'));
  });

  test(
    'cover fallback reuses the acquired thumbnail slot with comic id',
    () async {
      const coverUrl = 'https://example.com/cover.bin';
      await CacheManager().writeCache(
        'https://example.com/cover.bin@thumbnail-test-source@comic-1',
        [1, 2, 3],
      );

      var loadedComicId = '';
      ComicSourceManager().add(
        _buildThumbnailTestSource(
          getThumbnailLoadingConfig: (imageKey) =>
              imageKey == 'cover.placeholder'
              ? {'url': 'cover.placeholder'}
              : {},
          loadComicInfo: (id) async {
            loadedComicId = id;
            return Res(
              ComicDetails.fromJson({
                'title': 'Title',
                'cover': coverUrl,
                'description': '',
                'tags': <String, List<String>>{},
                'sourceKey': 'thumbnail-test-source',
                'comicId': id,
              }),
            );
          },
        ),
      );

      ImageDownloader.thumbnailLoadingCount =
          ImageDownloader.debugMaxThumbnailLoadingCount - 1;

      final progress = await ImageDownloader.loadThumbnail(
        'cover.placeholder',
        'thumbnail-test-source',
        'comic-1',
      ).last.timeout(const Duration(seconds: 2));

      expect(loadedComicId, 'comic-1');
      expect(progress.imageBytes, [1, 2, 3]);
      expect(
        ImageDownloader.thumbnailLoadingCount,
        ImageDownloader.debugMaxThumbnailLoadingCount - 1,
      );
    },
  );

  test('cached thumbnails bypass saturated thumbnail slots', () async {
    await CacheManager().writeCache(
      'https://example.com/cached-cover.jpg@thumbnail-test-source@comic-1',
      [4, 5, 6],
    );
    ImageDownloader.thumbnailLoadingCount =
        ImageDownloader.debugMaxThumbnailLoadingCount;

    final progress = await ImageDownloader.loadThumbnail(
      'https://example.com/cached-cover.jpg',
      'thumbnail-test-source',
      'comic-1',
    ).last.timeout(const Duration(seconds: 1));

    expect(progress.imageBytes, [4, 5, 6]);
    expect(
      ImageDownloader.thumbnailLoadingCount,
      ImageDownloader.debugMaxThumbnailLoadingCount,
    );
  });

  test(
    'background thumbnail work cannot occupy foreground reserved slots',
    () async {
      final acquisitions = <String>[];
      final backgroundLoads = <Future<void>>[];

      for (
        var i = 0;
        i < ImageDownloader.debugMaxBackgroundThumbnailLoadingCount + 1;
        i++
      ) {
        backgroundLoads.add(
          _acquireThumbnailSlot(
            'background-$i',
            acquisitions,
            priority: ThumbnailLoadPriority.background,
          ),
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        acquisitions,
        List.generate(
          ImageDownloader.debugMaxBackgroundThumbnailLoadingCount,
          (index) => 'background-$index',
        ),
      );
      expect(
        ImageDownloader.thumbnailLoadingCount,
        ImageDownloader.debugMaxBackgroundThumbnailLoadingCount,
      );

      final visible = _acquireThumbnailSlot('visible-cover', acquisitions);
      await visible.timeout(const Duration(seconds: 1));
      expect(acquisitions, contains('visible-cover'));

      for (
        var i = 0;
        i < ImageDownloader.debugMaxBackgroundThumbnailLoadingCount;
        i++
      ) {
        ImageDownloader.debugReleaseThumbnailLoadingSlot(
          priority: ThumbnailLoadPriority.background,
        );
      }

      await backgroundLoads.last.timeout(const Duration(seconds: 1));
      expect(acquisitions.last, 'background-6');

      ImageDownloader.debugReleaseThumbnailLoadingSlot(
        priority: ThumbnailLoadPriority.background,
      );
      ImageDownloader.debugReleaseThumbnailLoadingSlot();
      expect(ImageDownloader.thumbnailLoadingCount, 0);
    },
  );

  test('foreground thumbnail bursts still allow background progress', () async {
    final acquisitions = <String>[];
    final visibleLoads = <Future<void>>[];

    for (
      var i = 0;
      i < ImageDownloader.debugMaxConsecutiveForegroundThumbnailSlots;
      i++
    ) {
      visibleLoads.add(_acquireThumbnailSlot('visible-$i', acquisitions));
    }

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      acquisitions,
      List.generate(
        ImageDownloader.debugMaxConsecutiveForegroundThumbnailSlots,
        (index) => 'visible-$index',
      ),
    );

    final background = _acquireThumbnailSlot(
      'background-cover',
      acquisitions,
      priority: ThumbnailLoadPriority.background,
    );

    ImageDownloader.debugReleaseThumbnailLoadingSlot();
    await background.timeout(const Duration(seconds: 1));
    expect(acquisitions.last, 'background-cover');

    ImageDownloader.debugReleaseThumbnailLoadingSlot(
      priority: ThumbnailLoadPriority.background,
    );

    for (
      var i = 1;
      i < ImageDownloader.debugMaxConsecutiveForegroundThumbnailSlots;
      i++
    ) {
      ImageDownloader.debugReleaseThumbnailLoadingSlot();
    }
    expect(ImageDownloader.thumbnailLoadingCount, 0);
  });
}

Future<void> _acquireSlot(
  int id,
  List<int> acquisitions, {
  ThumbnailLoadPriority priority = ThumbnailLoadPriority.foregroundVisible,
}) async {
  await CachedImageProvider.debugAcquireLoadingSlot(() {}, priority: priority);
  acquisitions.add(id);
}

Future<void> _acquireThumbnailSlot(
  String id,
  List<String> acquisitions, {
  ThumbnailLoadPriority priority = ThumbnailLoadPriority.foregroundVisible,
}) async {
  await ImageDownloader.debugAcquireThumbnailLoadingSlot(
    () {},
    priority: priority,
  );
  acquisitions.add(id);
}

class _TestImageLoadingStopped implements Exception {}

ComicSource _buildThumbnailTestSource({
  required Map<String, dynamic> Function(String imageKey)
  getThumbnailLoadingConfig,
  required LoadComicFunc loadComicInfo,
}) {
  return ComicSource(
    'Thumbnail Test Source',
    'thumbnail-test-source',
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loadComicInfo,
    null,
    null,
    null,
    getThumbnailLoadingConfig,
    '',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}
