library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_memory_info/flutter_memory_info.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera/pages/reader/gesture_logic.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/custom_slider.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/chapter_pages_repository.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_details_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/clipboard_image.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/overlay_entry.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/volume.dart';
import 'package:window_manager/window_manager.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

part 'scaffold.dart';

part 'images.dart';

part 'gesture.dart';

part 'comic_image.dart';

part 'loading.dart';

part 'chapters.dart';

part 'chapter_comments.dart';

extension _ReaderContext on BuildContext {
  _ReaderState get reader => findAncestorStateOfType<_ReaderState>()!;

  _ReaderScaffoldState get readerScaffold =>
      findAncestorStateOfType<_ReaderScaffoldState>()!;
}

@visibleForTesting
int? computeReaderHistoryPage({
  required int page,
  required int maxPage,
  required int imageCount,
  required int imagesPerPage,
  required bool showSingleImageOnFirstPage,
}) {
  if (imageCount <= 0 || maxPage <= 0) {
    return null;
  }
  if (page >= maxPage) {
    return imageCount;
  }
  if (!showSingleImageOnFirstPage || imagesPerPage == 1) {
    return (page - 1) * imagesPerPage + 1;
  }
  if (page == 1) {
    return 1;
  }
  return (page - 2) * imagesPerPage + 2;
}

@visibleForTesting
int? computeReaderDisplayPageForImageIndex({
  required int imageIndex,
  required int imageCount,
  required int imagesPerPage,
  required bool showSingleImageOnFirstPage,
}) {
  if (imageIndex < 0 || imageIndex >= imageCount || imageCount <= 0) {
    return null;
  }
  if (!showSingleImageOnFirstPage || imagesPerPage == 1) {
    return imageIndex ~/ imagesPerPage + 1;
  }
  if (imageIndex == 0) {
    return 1;
  }
  return 2 + ((imageIndex - 1) ~/ imagesPerPage);
}

@visibleForTesting
int? computeReaderImageStartIndexForDisplayPage({
  required int page,
  required int imageCount,
  required int imagesPerPage,
  required bool showSingleImageOnFirstPage,
}) {
  if (imageCount <= 0 || page <= 0) {
    return null;
  }
  if (!showSingleImageOnFirstPage || imagesPerPage == 1) {
    final index = (page - 1) * imagesPerPage;
    return index >= imageCount ? null : index;
  }
  if (page == 1) {
    return 0;
  }
  final index = (page - 2) * imagesPerPage + 1;
  return index >= imageCount ? null : index;
}

@visibleForTesting
double? normalizeReaderInitialScale(double? initialScale) {
  if (initialScale == null || !initialScale.isFinite || initialScale <= 0) {
    return null;
  }
  return initialScale;
}

@visibleForTesting
double? computeReaderZoomInScale(double? initialScale) {
  final normalized = normalizeReaderInitialScale(initialScale);
  if (normalized == null) {
    return null;
  }
  return normalized * 1.75;
}

@visibleForTesting
double? computeReaderDoubleTapZoomTarget({
  required double? currentScale,
  required double? initialScale,
}) {
  final normalized = normalizeReaderInitialScale(initialScale);
  if (normalized == null) {
    return null;
  }
  return currentScale != normalized ? normalized : normalized * 1.75;
}

@visibleForTesting
bool shouldEnableReaderLongPressZoom(Object? value) {
  return normalizeBoolSetting(value, true);
}

@visibleForTesting
bool shouldShowReaderClockAndBatteryInfo(Object? value) {
  return normalizeBoolSetting(value, true);
}

@visibleForTesting
bool shouldShowReaderSystemStatusBar(Object? value) {
  return normalizeBoolSetting(value, false);
}

@visibleForTesting
bool shouldEnableReaderVolumeKey(Object? value) {
  return normalizeBoolSetting(value, true);
}

@visibleForTesting
bool shouldEnableReaderPageAnimation(Object? value) {
  return normalizeBoolSetting(value, true);
}

@visibleForTesting
bool shouldLimitReaderImageWidth(Object? value) {
  return normalizeBoolSetting(value, true);
}

@visibleForTesting
bool shouldShowSingleImageOnFirstPage(Object? value) {
  return normalizeBoolSetting(value, false);
}

@visibleForTesting
int normalizeReaderImagesPerPage(Object? value) {
  final normalized = normalizeNumSetting(value, 1).toInt();
  return normalized.clamp(1, 5);
}

@visibleForTesting
int normalizeAutoPageTurningIntervalSeconds(Object? value) {
  final normalized = normalizeNumSetting(value, 5).toInt();
  return normalized.clamp(1, 20);
}

@visibleForTesting
int normalizeReaderPageForLoadedImages({
  required int page,
  required int maxPage,
}) {
  if (maxPage <= 0) {
    return 1;
  }
  return page.clamp(1, maxPage);
}

@visibleForTesting
int normalizeReaderInitialChapter({
  required int? requestedChapter,
  required int? requestedGroup,
  required ComicChapters? chapters,
}) {
  var chapter = requestedChapter ?? 1;
  if (chapter < 1) {
    chapter = 1;
  }
  final maxChapter = chapters?.length ?? 1;
  if (maxChapter <= 0) {
    return 1;
  }
  if (requestedGroup == null) {
    return chapter.clamp(1, maxChapter);
  }
  if (requestedGroup < 1) {
    return 1;
  }
  if (chapters == null || !chapters.isGrouped) {
    return chapter.clamp(1, maxChapter);
  }
  final groups = chapters.groups.toList();
  if (requestedGroup > groups.length) {
    return 1;
  }
  var offset = 0;
  for (var i = 0; i < requestedGroup - 1; i++) {
    offset += chapters.getGroup(groups[i]).length;
  }
  final groupLength = chapters.getGroup(groups[requestedGroup - 1]).length;
  if (groupLength <= 0) {
    return 1;
  }
  return (offset + chapter.clamp(1, groupLength)).clamp(1, maxChapter);
}

@visibleForTesting
({int groupIndex, int chapterInGroup})? resolveGroupedReaderChapterPosition({
  required ComicChapters chapters,
  required int chapter,
}) {
  if (!chapters.isGrouped || chapter < 1) {
    return null;
  }
  var remainingChapter = chapter;
  for (var groupIndex = 0; groupIndex < chapters.groupCount; groupIndex++) {
    final groupLength = chapters.getGroupByIndex(groupIndex).length;
    if (groupLength <= 0) {
      continue;
    }
    if (remainingChapter <= groupLength) {
      return (groupIndex: groupIndex, chapterInGroup: remainingChapter);
    }
    remainingChapter -= groupLength;
  }
  return null;
}

class Reader extends StatefulWidget {
  const Reader({
    super.key,
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    this.initialPage,
    this.initialChapter,
    this.initialChapterGroup,
    required this.author,
    required this.tags,
  });

  final ComicType type;

  final String author;

  final List<String> tags;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  /// Starts from 1, invalid values equal to 1
  final int? initialPage;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapter;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapterGroup;

  final History history;

  @override
  State<Reader> createState() => _ReaderState();
}

@visibleForTesting
Widget buildReaderOverlayHostForTest({required Widget child}) {
  return _ReaderOverlayHost(child: child);
}

@visibleForTesting
bool canReaderSwitchChapter({
  required int currentChapter,
  required int targetChapter,
  required int maxChapter,
  required bool isLoading,
}) {
  if (isLoading || targetChapter == currentChapter) {
    return false;
  }
  return targetChapter >= 1 && targetChapter <= maxChapter;
}

@visibleForTesting
class ReaderDeferredWorkScheduler {
  ReaderDeferredWorkScheduler({
    required this.remainingDelay,
    required this.schedulePostFrame,
  });

  final Duration Function() remainingDelay;
  final void Function(VoidCallback task) schedulePostFrame;
  final Map<Object, VoidCallback> _pendingTasks = {};
  final Map<Object, Timer> _timers = {};

  void run(Object key, VoidCallback task) {
    final remaining = remainingDelay();
    void runPostFrame(VoidCallback callback) {
      schedulePostFrame(callback);
    }

    if (remaining <= Duration.zero) {
      _timers.remove(key)?.cancel();
      _pendingTasks.remove(key);
      runPostFrame(task);
      return;
    }

    _pendingTasks[key] = task;
    if (_timers.containsKey(key)) {
      return;
    }
    _timers[key] = Timer(remaining, () {
      _timers.remove(key);
      final pending = _pendingTasks.remove(key);
      if (pending != null) {
        runPostFrame(pending);
      }
    });
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pendingTasks.clear();
  }
}

@visibleForTesting
Duration computeReaderDeferredWorkRemaining({
  required DateTime startedAt,
  required DateTime now,
  required Duration delay,
}) {
  final remaining = delay - now.difference(startedAt);
  return remaining > Duration.zero ? remaining : Duration.zero;
}

Duration _maxDuration(Duration a, Duration b) {
  return a >= b ? a : b;
}

class _ReaderState extends State<Reader>
    with _ReaderLocation, _ReaderWindow, _VolumeListener, _ImagePerPageHandler {
  static const _initialReaderBackgroundWorkDelay = Duration(milliseconds: 2500);
  static const _firstHistoryWriteDelay = Duration(milliseconds: 1200);
  static const _subsequentHistoryWriteDelay = Duration(seconds: 1);

  final Set<int> _completedDownloadedChapters = {};
  int _chapterPrefetchGeneration = 0;
  String? _nextChapterPrefetchChapterId;
  List<String>? _nextChapterPrefetchPages;
  int _nextChapterPrefetchedImageCount = 0;
  bool _nextChapterPrefetchRetryScheduled = false;
  bool _nextChapterPrefetchRetryWarmRemainingImages = false;
  Timer? _nextChapterPrefetchWarmupTimer;
  bool _nextChapterPrefetchWarmupWantsRemainingImages = false;
  late final DateTime _readerMountedAt;
  late final ReaderDeferredWorkScheduler _initialReaderWorkScheduler;
  bool _historyWriteHasRun = false;

  @override
  void update() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  /// The maximum page number for images only (excluding chapter comments page).
  /// This is used for display purposes and history recording.
  @override
  int get maxPage {
    if (images == null) return 1;
    return !showSingleImageOnFirstPage()
        ? (images!.length / imagesPerPage).ceil()
        : 1 + ((images!.length - 1) / imagesPerPage).ceil();
  }

  /// Total pages including chapter comments page (used for internal page control).
  @override
  int get totalPages {
    var pages = maxPage;
    if (_shouldShowChapterCommentsAtEnd) pages++;
    return pages;
  }

  /// Whether the current page is the chapter comments page.
  @override
  bool get isOnChapterCommentsPage {
    return _shouldShowChapterCommentsAtEnd && _page > maxPage;
  }

  bool get _shouldShowChapterCommentsAtEnd {
    if (mode != ReaderMode.galleryLeftToRight &&
        mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (widget.chapters == null) return false;
    var source = ComicSource.find(type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  @override
  ComicType get type => widget.type;

  @override
  String get cid => widget.cid;

  String get eid => widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0';

  @override
  List<String>? images;

  @override
  late ReaderMode mode;

  @override
  bool get isPortrait =>
      MediaQuery.of(context).orientation == Orientation.portrait;

  History? history;

  @override
  bool isLoading = false;

  var focusNode = FocusNode();
  late final int _previousImageCacheMaximumSizeBytes;

  @override
  void initState() {
    _previousImageCacheMaximumSizeBytes =
        PaintingBinding.instance.imageCache.maximumSizeBytes;
    _readerMountedAt = DateTime.now();
    _initialReaderWorkScheduler = ReaderDeferredWorkScheduler(
      remainingDelay: () => _initialReaderBackgroundWorkRemaining,
      schedulePostFrame: (task) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            task();
          }
        });
      },
    );
    // mode = ReaderMode.fromKey(appdata.settings['readerMode']);
    mode = ReaderMode.fromKey(
      appdata.settings.getReaderSetting(cid, type.sourceKey, 'readerMode'),
    );
    _page = widget.initialPage ?? 1;
    if (_page < 1) {
      _page = 1;
    }
    chapter = normalizeReaderInitialChapter(
      requestedChapter: widget.initialChapter,
      requestedGroup: widget.initialChapterGroup,
      chapters: widget.chapters,
    );
    if (widget.initialPage != null) {
      _page = widget.initialPage!;
      if (_page < 1) {
        _page = 1;
      }
    }
    history = widget.history;
    final showSystemStatusBar = shouldShowReaderSystemStatusBar(
      appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'showSystemStatusBar',
      ),
    );
    if (!showSystemStatusBar) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (shouldEnableReaderVolumeKey(
      appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'enableTurnPageByVolumeKey',
      ),
    )) {
      handleVolumeEvent();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(setImageCacheSize());
      Future.microtask(() {
        if (mounted) {
          LocalFavoritesManager().onRead(cid, type, notify: false);
        }
      });
    });
    super.initState();
  }

  bool _isInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      initImagesPerPage(widget.initialPage ?? 1);
      _isInitialized = true;
    } else {
      // For orientation changed
      _checkImagesPerPageChange();
    }
    initReaderWindow();
  }

  Future<void> setImageCacheSize() async {
    try {
      var availableRAM = await MemoryInfo.getFreePhysicalMemorySize();
      if (availableRAM == null || !mounted) return;
      int maxImageCacheSize;
      if (availableRAM < 1 << 30) {
        maxImageCacheSize = 100 << 20;
      } else if (availableRAM < 2 << 30) {
        maxImageCacheSize = 200 << 20;
      } else if (availableRAM < 4 << 30) {
        maxImageCacheSize = 300 << 20;
      } else {
        maxImageCacheSize = 500 << 20;
      }
      Log.info(
        "Reader",
        "Detect available RAM: $availableRAM, set image cache size to $maxImageCacheSize",
      );
      PaintingBinding.instance.imageCache.maximumSizeBytes = maxImageCacheSize;
    } catch (e, s) {
      Log.error("Reader", "Failed to set reader image cache size: $e", s);
    }
  }

  @override
  void dispose() {
    _flushPendingHistoryUpdate();
    _initialReaderWorkScheduler.dispose();
    _resetNextChapterPrefetchState();
    _deleteReadChapterIfNeeded(chapter);
    if (isFullscreen) {
      fullscreen();
    }
    autoPageTurningTimer?.cancel();
    focusNode.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    stopVolumeEvent();
    Future.microtask(() {
      DataSync().onDataChanged();
    });
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        _previousImageCacheMaximumSizeBytes;
    disposeReaderWindow();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _checkImagesPerPageChange();
    Widget readerContent = _ReaderGestureDetector(
      child: _ReaderImages(key: Key(chapter.toString())),
    );
    return KeyboardListener(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: onKeyEvent,
      child: _ReaderOverlayHost(child: _ReaderScaffold(child: readerContent)),
    );
  }

  void onKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.f12 && event is KeyUpEvent) {
      fullscreen();
    }
    _imageViewController?.handleKeyEvent(event);
  }

  @override
  bool toChapter(int c, {bool toLastPage = false}) {
    if (!canReaderSwitchChapter(
      currentChapter: chapter,
      targetChapter: c,
      maxChapter: maxChapter,
      isLoading: isLoading,
    )) {
      return false;
    }
    final previousChapter = chapter;
    _flushPendingHistoryUpdate();
    _resetNextChapterPrefetchState();
    _deleteReadChapterIfNeeded(previousChapter);
    ImageDownloader.cancelAllLoadingImages();
    ComicImage.clear();
    setState(() {
      images = null;
      isLoading = true;
      _imageViewController = null;
      chapter = c;
      _page = 1;
      _jumpToLastPageOnLoad = toLastPage;
    });
    return true;
  }

  void _deleteReadChapterIfNeeded(int chapterNumber) {
    if (widget.type == ComicType.local ||
        widget.chapters == null ||
        appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'autoDeleteReadChapters',
            ) !=
            true ||
        !_completedDownloadedChapters.contains(chapterNumber)) {
      return;
    }

    final chapterId = widget.chapters!.ids.elementAtOrNull(chapterNumber - 1);
    if (chapterId == null) {
      return;
    }
    final localComic = LocalManager().find(cid, type);
    if (localComic == null ||
        !localComic.downloadedChapters.contains(chapterId)) {
      return;
    }
    _completedDownloadedChapters.remove(chapterNumber);
    Future.microtask(() async {
      try {
        await LocalManager().deleteComicChapters(localComic, [chapterId]);
      } catch (error, stackTrace) {
        Log.error(
          'LocalArchive',
          'Failed to auto-delete downloaded chapter $chapterId: $error',
          stackTrace,
        );
      }
    });
  }

  @override
  int get maxChapter => widget.chapters?.length ?? 1;

  @override
  void onPageChanged() {
    updateHistory();
  }

  /// Prevent multiple history updates in a short time.
  /// `HistoryManager().addHistoryAsync` is a high-cost operation because it creates a new isolate.
  Timer? _updateHistoryTimer;

  void updateHistory() {
    if (history == null) {
      return;
    }
    final imageCount = images?.length ?? 0;
    if (imageCount <= 0 || maxPage <= 0) {
      return;
    }
    final historyPage = computeReaderHistoryPage(
      page: page,
      maxPage: maxPage,
      imageCount: imageCount,
      imagesPerPage: imagesPerPage,
      showSingleImageOnFirstPage: showSingleImageOnFirstPage(),
    );
    if (historyPage == null) {
      return;
    }
    history!.page = historyPage;
    // page >= maxPage handles both last image page and chapter comments page
    if (page >= maxPage) {
      _completedDownloadedChapters.add(chapter);
    }
    history!.maxPage = imageCount;
    if (widget.chapters?.isGrouped ?? false) {
      final position = resolveGroupedReaderChapterPosition(
        chapters: widget.chapters!,
        chapter: chapter,
      );
      if (position != null) {
        history!.readEpisode.add(
          '${position.groupIndex + 1}-${position.chapterInGroup}',
        );
        history!.ep = position.chapterInGroup;
        history!.group = position.groupIndex + 1;
      }
    } else {
      history!.readEpisode.add(chapter.toString());
      history!.ep = chapter;
    }
    history!.time = DateTime.now();
    _maybeWarmRemainingNextChapterImages();
    _updateHistoryTimer?.cancel();
    _updateHistoryTimer = Timer(_nextHistoryWriteDelay, () {
      _persistHistorySnapshot();
    });
  }

  void onChapterImagesResolved() {
    _prepareNextChapterPrefetchInBackground();
  }

  void _maybeWarmRemainingNextChapterImages() {
    if (images == null || images!.isEmpty) {
      return;
    }
    final threshold = math.max(
      1,
      maxPage -
          appdata.settings.intValue('preloadImageCount', fallback: 4, min: 0) +
          1,
    );
    if (page >= threshold) {
      _prepareNextChapterPrefetchInBackground(warmRemainingImages: true);
    }
  }

  void _resetNextChapterPrefetchState() {
    _chapterPrefetchGeneration++;
    _nextChapterPrefetchWarmupTimer?.cancel();
    _nextChapterPrefetchWarmupTimer = null;
    _nextChapterPrefetchWarmupWantsRemainingImages = false;
    _nextChapterPrefetchChapterId = null;
    _nextChapterPrefetchPages = null;
    _nextChapterPrefetchedImageCount = 0;
    _nextChapterPrefetchRetryScheduled = false;
    _nextChapterPrefetchRetryWarmRemainingImages = false;
    ImageDownloader.cancelReaderPrefetches();
  }

  String? _findNextChapterId() {
    return widget.chapters?.ids.elementAtOrNull(chapter);
  }

  Future<void> _prepareNextChapterPrefetch({
    bool warmRemainingImages = false,
  }) async {
    if (type == ComicType.local || widget.chapters == null) {
      return;
    }
    if (_deferNextChapterPrefetchUntilReaderWarmsUp(warmRemainingImages)) {
      _logReaderPerf('reader next chapter prefetch warmup deferred');
      return;
    }
    final nextChapterId = _findNextChapterId();
    if (nextChapterId == null) {
      return;
    }

    if (ImageDownloader.hasQueuedOrActiveReaderLoad(
      ReaderImageLoadPriority.sameChapterPrefetch,
    )) {
      _logReaderPerf('reader next chapter prefetch deferred');
      _scheduleDeferredNextChapterPrefetchRetry(
        warmRemainingImages: warmRemainingImages,
      );
      return;
    }

    final generation = _chapterPrefetchGeneration;
    var pages = _nextChapterPrefetchChapterId == nextChapterId
        ? _nextChapterPrefetchPages
        : null;

    if (pages == null) {
      final res = await ChapterPagesRepository().load(
        type.sourceKey,
        cid,
        nextChapterId,
        onBackgroundUpdate: (updatedPages) async {
          if (!mounted ||
              generation != _chapterPrefetchGeneration ||
              _findNextChapterId() != nextChapterId) {
            return;
          }
          _nextChapterPrefetchChapterId = nextChapterId;
          _nextChapterPrefetchPages = updatedPages;
          _nextChapterPrefetchedImageCount = math.min(
            _nextChapterPrefetchedImageCount,
            updatedPages.length,
          );
          final shouldWarmRemaining =
              page >=
              math.max(
                1,
                maxPage -
                    appdata.settings.intValue(
                      'preloadImageCount',
                      fallback: 4,
                      min: 0,
                    ) +
                    1,
              );
          await _warmNextChapterImages(
            nextChapterId,
            updatedPages,
            generation: generation,
            warmRemainingImages: shouldWarmRemaining,
          );
        },
      );
      if (!res.success ||
          !mounted ||
          generation != _chapterPrefetchGeneration ||
          _findNextChapterId() != nextChapterId) {
        return;
      }
      _nextChapterPrefetchRetryScheduled = false;
      _nextChapterPrefetchRetryWarmRemainingImages = false;
      pages = res.data;
      _nextChapterPrefetchChapterId = nextChapterId;
      _nextChapterPrefetchPages = pages;
      _nextChapterPrefetchedImageCount = 0;
    }

    await _warmNextChapterImages(
      nextChapterId,
      pages,
      generation: generation,
      warmRemainingImages: warmRemainingImages,
    );
  }

  void _prepareNextChapterPrefetchInBackground({
    bool warmRemainingImages = false,
  }) {
    unawaited(
      _prepareNextChapterPrefetch(
        warmRemainingImages: warmRemainingImages,
      ).catchError((Object error, StackTrace stackTrace) {
        Log.error(
          "Reader",
          "Failed to prepare next chapter prefetch: $error",
          stackTrace,
        );
      }),
    );
  }

  Future<void> _warmNextChapterImages(
    String chapterId,
    List<String> pages, {
    required int generation,
    required bool warmRemainingImages,
  }) async {
    if (!mounted ||
        generation != _chapterPrefetchGeneration ||
        _findNextChapterId() != chapterId) {
      return;
    }

    final maxTargetCount = warmRemainingImages
        ? pages.length
        : math.min(8, pages.length);
    if (maxTargetCount <= _nextChapterPrefetchedImageCount) {
      return;
    }

    final sourceKey = type.sourceKey;
    for (int i = _nextChapterPrefetchedImageCount; i < maxTargetCount; i++) {
      if (!mounted ||
          generation != _chapterPrefetchGeneration ||
          _findNextChapterId() != chapterId) {
        return;
      }
      final imageKey = pages[i];
      if (imageKey.startsWith('file://')) {
        continue;
      }
      ImageDownloader.prefetchReaderImage(
        imageKey,
        sourceKey,
        cid,
        chapterId,
        priority: ReaderImageLoadPriority.nextChapterPrefetch,
      );
    }
    _nextChapterPrefetchedImageCount = maxTargetCount;
  }

  void _scheduleDeferredNextChapterPrefetchRetry({
    required bool warmRemainingImages,
  }) {
    _nextChapterPrefetchRetryWarmRemainingImages =
        _nextChapterPrefetchRetryWarmRemainingImages || warmRemainingImages;
    if (_nextChapterPrefetchRetryScheduled) {
      return;
    }
    _nextChapterPrefetchRetryScheduled = true;
    final generation = _chapterPrefetchGeneration;
    Future.delayed(const Duration(milliseconds: 200), () {
      final shouldWarmRemaining = _nextChapterPrefetchRetryWarmRemainingImages;
      _nextChapterPrefetchRetryScheduled = false;
      _nextChapterPrefetchRetryWarmRemainingImages = false;
      if (!mounted || generation != _chapterPrefetchGeneration) {
        return;
      }
      _prepareNextChapterPrefetchInBackground(
        warmRemainingImages: shouldWarmRemaining,
      );
    });
  }

  Duration get _initialReaderBackgroundWorkRemaining {
    final mountedWarmupRemaining = computeReaderDeferredWorkRemaining(
      startedAt: _readerMountedAt,
      now: DateTime.now(),
      delay: _initialReaderBackgroundWorkDelay,
    );
    return _maxDuration(
      mountedWarmupRemaining,
      ImageDownloader.readerLifecycleQuietRemaining,
    );
  }

  Duration get _nextHistoryWriteDelay {
    final lifecycleQuietRemaining =
        ImageDownloader.readerLifecycleQuietRemaining;
    if (_historyWriteHasRun) {
      return _maxDuration(
        _subsequentHistoryWriteDelay,
        lifecycleQuietRemaining,
      );
    }
    final firstWriteRemaining = computeReaderDeferredWorkRemaining(
      startedAt: _readerMountedAt,
      now: DateTime.now(),
      delay: _firstHistoryWriteDelay,
    );
    return _maxDuration(firstWriteRemaining, lifecycleQuietRemaining);
  }

  bool _deferNextChapterPrefetchUntilReaderWarmsUp(bool warmRemainingImages) {
    final remaining = _initialReaderBackgroundWorkRemaining;
    if (remaining <= Duration.zero) {
      return false;
    }
    _nextChapterPrefetchWarmupWantsRemainingImages =
        _nextChapterPrefetchWarmupWantsRemainingImages || warmRemainingImages;
    if (_nextChapterPrefetchWarmupTimer != null) {
      return true;
    }
    final generation = _chapterPrefetchGeneration;
    _nextChapterPrefetchWarmupTimer = Timer(remaining, () {
      _nextChapterPrefetchWarmupTimer = null;
      final shouldWarmRemaining =
          _nextChapterPrefetchWarmupWantsRemainingImages;
      _nextChapterPrefetchWarmupWantsRemainingImages = false;
      if (!mounted || generation != _chapterPrefetchGeneration) {
        return;
      }
      _prepareNextChapterPrefetchInBackground(
        warmRemainingImages: shouldWarmRemaining,
      );
    });
    return true;
  }

  void runAfterInitialReaderWarmup(Object key, VoidCallback task) {
    _initialReaderWorkScheduler.run(key, task);
  }

  void _flushPendingHistoryUpdate() {
    if (_updateHistoryTimer == null || history == null) {
      return;
    }
    _updateHistoryTimer?.cancel();
    _persistHistorySnapshot();
  }

  void _persistHistorySnapshot() {
    _updateHistoryTimer = null;
    final currentHistory = history;
    if (currentHistory == null) {
      return;
    }
    _historyWriteHasRun = true;
    unawaited(
      HistoryManager()
          .addHistoryAsync(_snapshotHistory(currentHistory), notify: false)
          .catchError((Object error, StackTrace stackTrace) {
            Log.error(
              "Reader",
              "Failed to persist reader history: $error",
              stackTrace,
            );
          }),
    );
  }

  History _snapshotHistory(History source) {
    final snapshot = History.fromMap({
      'type': source.type.value,
      'sourceKey': source.sourceKey,
      'time': source.time.millisecondsSinceEpoch,
      'title': source.title,
      'subtitle': source.subtitle,
      'cover': source.cover,
      'ep': source.ep,
      'page': source.page,
      'id': source.id,
      'readEpisode': source.readEpisode.toList(),
      'max_page': source.maxPage,
    });
    snapshot.group = source.group;
    return snapshot;
  }

  void _logReaderPerf(String label) {
    if (!kDebugMode) {
      return;
    }
    Log.info('Reader', '[perf] $label ${type.sourceKey}@$cid#$eid');
  }

  bool get isFirstChapterOfGroup {
    if (widget.chapters?.isGrouped ?? false) {
      final position = resolveGroupedReaderChapterPosition(
        chapters: widget.chapters!,
        chapter: chapter,
      );
      return position?.chapterInGroup == 1;
    }
    return chapter == 1;
  }

  bool get isLastChapterOfGroup {
    if (widget.chapters?.isGrouped ?? false) {
      final position = resolveGroupedReaderChapterPosition(
        chapters: widget.chapters!,
        chapter: chapter,
      );
      if (position == null) {
        return true;
      }
      return position.chapterInGroup ==
          widget.chapters!.getGroupByIndex(position.groupIndex).length;
    }
    return chapter == maxChapter;
  }

  /// Get the size of the reader.
  /// The size is not always the same as the size of the screen.
  Size get size {
    var renderBox = context.findRenderObject() as RenderBox;
    return renderBox.size;
  }
}

class _ReaderOverlayHost extends StatefulWidget {
  const _ReaderOverlayHost({required this.child});

  final Widget child;

  @override
  State<_ReaderOverlayHost> createState() => _ReaderOverlayHostState();
}

class _ReaderOverlayHostState extends State<_ReaderOverlayHost> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (context) => widget.child,
  );

  @override
  void didUpdateWidget(covariant _ReaderOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    removeAndDisposeOverlayEntry(_entry);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: [_entry]);
  }
}

abstract mixin class _ImagePerPageHandler {
  late int _lastImagesPerPage;

  late bool _lastOrientation;

  /// Track if we were on the chapter comments page before orientation change
  bool _wasOnCommentsPage = false;

  bool get isPortrait;

  int get page;

  set page(int value);

  ReaderMode get mode;

  String get cid;

  ComicType get type;

  /// Whether the current page is the chapter comments page
  bool get isOnChapterCommentsPage;

  /// Get the max page (excluding comments page)
  int get maxPage;

  /// Get images list for calculating maxPage
  List<String>? get images;

  void initImagesPerPage(int initialPage) {
    _lastImagesPerPage = imagesPerPage;
    _lastOrientation = isPortrait;
    _wasOnCommentsPage = false;
    if (imagesPerPage != 1) {
      if (showSingleImageOnFirstPage()) {
        page = ((initialPage - 1) / imagesPerPage).ceil() + 1;
      } else {
        page = (initialPage / imagesPerPage).ceil();
      }
    }
  }

  bool showSingleImageOnFirstPage() {
    return shouldShowSingleImageOnFirstPage(
      appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'showSingleImageOnFirstPage',
      ),
    );
  }

  /// The number of images displayed on one screen
  int get imagesPerPage {
    if (mode.isContinuous) return 1;
    if (isPortrait) {
      return normalizeReaderImagesPerPage(
        appdata.settings.getReaderSetting(
          cid,
          type.sourceKey,
          'readerScreenPicNumberForPortrait',
        ),
      );
    }
    return normalizeReaderImagesPerPage(
      appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'readerScreenPicNumberForLandscape',
      ),
    );
  }

  /// Calculate maxPage with a specific imagesPerPage value
  int _calcMaxPage(int imagesPerPageValue) {
    if (images == null) return 1;
    return !showSingleImageOnFirstPage()
        ? (images!.length / imagesPerPageValue).ceil()
        : 1 + ((images!.length - 1) / imagesPerPageValue).ceil();
  }

  /// Check if the number of images per page has changed
  void _checkImagesPerPageChange() {
    int currentImagesPerPage = imagesPerPage;
    bool currentOrientation = isPortrait;

    if (_lastImagesPerPage != currentImagesPerPage ||
        _lastOrientation != currentOrientation) {
      // Calculate old maxPage using old imagesPerPage to correctly determine
      // if we were on the comments page before the orientation change
      int oldMaxPage = _calcMaxPage(_lastImagesPerPage);
      _wasOnCommentsPage = page > oldMaxPage;

      _adjustPageForImagesPerPageChange(
        _lastImagesPerPage,
        currentImagesPerPage,
      );
      _lastImagesPerPage = currentImagesPerPage;
      _lastOrientation = currentOrientation;
    }
  }

  /// Adjust the page number when the number of images per page changes
  void _adjustPageForImagesPerPageChange(
    int oldImagesPerPage,
    int newImagesPerPage,
  ) {
    int previousImageIndex = 1;
    if (!showSingleImageOnFirstPage() || oldImagesPerPage == 1) {
      previousImageIndex = (page - 1) * oldImagesPerPage + 1;
    } else {
      if (page == 1) {
        previousImageIndex = 1;
      } else {
        previousImageIndex = (page - 2) * oldImagesPerPage + 2;
      }
    }

    int newPage;
    if (newImagesPerPage != 1) {
      if (showSingleImageOnFirstPage()) {
        newPage = ((previousImageIndex - 1) / newImagesPerPage).ceil() + 1;
      } else {
        newPage = (previousImageIndex / newImagesPerPage).ceil();
      }
    } else {
      newPage = previousImageIndex;
    }

    // Clamp to valid range (1 to maxPage)
    newPage = newPage.clamp(1, maxPage);

    // If we were on the comments page, stay on the comments page
    if (_wasOnCommentsPage) {
      page = maxPage + 1;
    } else {
      page = newPage;
    }
  }
}

abstract mixin class _VolumeListener {
  bool toNextPage();

  bool toPrevPage();

  bool toNextChapter();

  bool toPrevChapter({bool toLastPage = false});

  VolumeListener? volumeListener;

  void onDown() {
    if (!toNextPage()) {
      toNextChapter();
    }
  }

  void onUp() {
    if (!toPrevPage()) {
      toPrevChapter(toLastPage: true);
    }
  }

  void handleVolumeEvent() {
    if (!App.isAndroid) {
      // Currently only support Android
      return;
    }
    if (volumeListener != null) {
      volumeListener?.cancel();
    }
    volumeListener = VolumeListener(onDown: onDown, onUp: onUp)..listen();
  }

  void stopVolumeEvent() {
    if (volumeListener != null) {
      volumeListener?.cancel();
      volumeListener = null;
    }
  }
}

abstract mixin class _ReaderLocation {
  int _page = 1;
  int? _pendingPage;

  /// Flag to indicate that the page should jump to the last page after images are loaded.
  bool _jumpToLastPageOnLoad = false;

  int get page => _page;

  set page(int value) {
    _page = value;
    onPageChanged();
  }

  int chapter = 1;

  int get maxPage;

  /// Total pages including chapter comments page (for internal page control).
  int get totalPages;

  int get maxChapter;

  bool get isLoading;

  String get cid;

  ComicType get type;

  void update();

  bool enablePageAnimation(String cid, ComicType type) {
    return shouldEnableReaderPageAnimation(
      appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'enablePageAnimation',
      ),
    );
  }

  _ImageViewController? _imageViewController;

  void onPageChanged();

  void setPage(int page) {
    // Prevent page change during animation
    if (_animationCount > 0 && _pendingPage != null && page != _pendingPage) {
      return;
    }
    this.page = page;
  }

  bool _validatePage(int page) {
    return page >= 1 && page <= totalPages;
  }

  /// Returns true if the page is changed
  bool toNextPage() {
    return toPage(page + 1);
  }

  /// Returns true if the page is changed
  bool toPrevPage() {
    return toPage(page - 1);
  }

  int _animationCount = 0;

  bool toPage(int page) {
    if (_validatePage(page)) {
      if (page == this.page && page != 1 && page != totalPages) {
        return false;
      }
      final hasAnimation = enablePageAnimation(cid, type);
      final imageViewController = _imageViewController;
      if (hasAnimation && imageViewController != null) {
        _pendingPage = page;
        _animationCount++;
        update();
        void finishAnimation([Object? error, StackTrace? stackTrace]) {
          if (error != null) {
            Log.error('Reader page animation failed', error, stackTrace);
          }
          _animationCount = math.max(0, _animationCount - 1);
          if (_pendingPage == page) {
            _pendingPage = null;
          }
          update();
        }

        imageViewController
            .animateToPage(page)
            .then((_) => finishAnimation(), onError: finishAnimation);
      } else {
        this.page = page;
        update();
        imageViewController?.toPage(page);
      }
      return true;
    }
    return false;
  }

  bool get isPageAnimating => _animationCount > 0;

  bool _validateChapter(int chapter) {
    return chapter >= 1 && chapter <= maxChapter;
  }

  /// Returns true if the chapter is changed
  bool toNextChapter() {
    return toChapter(chapter + 1);
  }

  /// Returns true if the chapter is changed
  /// If [toLastPage] is true, the page will be set to the last page of the previous chapter.
  bool toPrevChapter({bool toLastPage = false}) {
    return toChapter(chapter - 1, toLastPage: toLastPage);
  }

  bool toChapter(int c, {bool toLastPage = false}) {
    if (_validateChapter(c) && !isLoading) {
      chapter = c;
      page = 1;
      _jumpToLastPageOnLoad = toLastPage;
      update();
      return true;
    }
    return false;
  }

  Timer? autoPageTurningTimer;

  void autoPageTurning(String cid, ComicType type) {
    if (autoPageTurningTimer != null) {
      autoPageTurningTimer!.cancel();
      autoPageTurningTimer = null;
    } else {
      final interval = normalizeAutoPageTurningIntervalSeconds(
        appdata.settings.getReaderSetting(
          cid,
          type.sourceKey,
          'autoPageTurningInterval',
        ),
      );
      autoPageTurningTimer = Timer.periodic(Duration(seconds: interval), (_) {
        if (page == maxPage) {
          autoPageTurningTimer!.cancel();
        }
        toNextPage();
      });
    }
  }
}

mixin class _ReaderWindow {
  bool isFullscreen = false;

  WindowFrameController? windowFrame;

  bool _isInit = false;

  WindowFrameController? _findWindowFrameController() {
    final context = App.rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return null;
    return WindowFrame.maybeOf(context);
  }

  void initReaderWindow() {
    if (!App.isDesktop || _isInit) return;
    final controller = _findWindowFrameController();
    if (controller == null) return;
    windowFrame = controller;
    controller.addCloseListener(onWindowClose);
    _isInit = true;
  }

  void fullscreen() async {
    if (!App.isDesktop) return;
    await windowManager.hide();
    await windowManager.setFullScreen(!isFullscreen);
    await windowManager.show();
    isFullscreen = !isFullscreen;
    final controller = windowFrame ?? _findWindowFrameController();
    controller?.setWindowFrame(!isFullscreen);
  }

  bool onWindowClose() {
    final navigator = App.rootNavigatorKey.currentState;
    if (navigator?.canPop() ?? false) {
      navigator?.pop();
      return false;
    } else {
      return true;
    }
  }

  void disposeReaderWindow() {
    if (!App.isDesktop) return;
    windowFrame?.removeCloseListener(onWindowClose);
    windowFrame = null;
    _isInit = false;
  }
}

enum ReaderMode {
  galleryLeftToRight('galleryLeftToRight'),
  galleryRightToLeft('galleryRightToLeft'),
  galleryTopToBottom('galleryTopToBottom'),
  continuousTopToBottom('continuousTopToBottom'),
  continuousLeftToRight('continuousLeftToRight'),
  continuousRightToLeft('continuousRightToLeft');

  final String key;

  bool get isGallery => key.startsWith('gallery');

  bool get isContinuous => key.startsWith('continuous');

  const ReaderMode(this.key);

  static ReaderMode fromKey(Object? key) {
    if (key is! String) {
      return galleryLeftToRight;
    }
    for (var mode in values) {
      if (mode.key == key) {
        return mode;
      }
    }
    return galleryLeftToRight;
  }
}

abstract interface class _ImageViewController {
  void toPage(int page);

  Future<void> animateToPage(int page);

  void handleDoubleTap(Offset location);

  void handleLongPressDown(Offset location);

  void handleLongPressUp(Offset location);

  void handleKeyEvent(KeyEvent event);

  /// Returns true if the event is handled.
  bool handleOnTap(Offset location);

  Future<Uint8List?> getImageByOffset(Offset offset);

  String? getImageKeyByOffset(Offset offset);
}
