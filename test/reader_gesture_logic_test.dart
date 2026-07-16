import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/gesture_logic.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  const viewport = Size(1000, 2000);

  test('normalizeSelectedReaderImageIndex rejects invalid selections', () {
    expect(normalizeSelectedReaderImageIndex(index: 0, imageCount: 2), 0);
    expect(normalizeSelectedReaderImageIndex(index: -1, imageCount: 2), isNull);
    expect(normalizeSelectedReaderImageIndex(index: 2, imageCount: 2), isNull);
    expect(normalizeSelectedReaderImageIndex(index: 0, imageCount: 0), isNull);
  });

  test('reader image selection result requires mounted unchanged owner', () {
    expect(
      shouldUseReaderImageSelectionResult(
        mounted: true,
        imageViewControllerUnchanged: true,
        location: const Offset(1, 2),
      ),
      isTrue,
    );
    expect(
      shouldUseReaderImageSelectionResult(
        mounted: false,
        imageViewControllerUnchanged: true,
        location: const Offset(1, 2),
      ),
      isFalse,
    );
    expect(
      shouldUseReaderImageSelectionResult(
        mounted: true,
        imageViewControllerUnchanged: false,
        location: const Offset(1, 2),
      ),
      isFalse,
    );
    expect(
      shouldUseReaderImageSelectionResult(
        mounted: true,
        imageViewControllerUnchanged: true,
        location: null,
      ),
      isFalse,
    );
  });

  test('reader zoom helpers reject unavailable initial scale', () {
    expect(normalizeReaderInitialScale(1.0), 1.0);
    expect(normalizeReaderInitialScale(null), isNull);
    expect(normalizeReaderInitialScale(0), isNull);
    expect(normalizeReaderInitialScale(double.nan), isNull);

    expect(computeReaderZoomInScale(2), 3.5);
    expect(computeReaderZoomInScale(null), isNull);
    expect(
      computeReaderDoubleTapZoomTarget(currentScale: 2, initialScale: 2),
      3.5,
    );
    expect(
      computeReaderDoubleTapZoomTarget(currentScale: 3.5, initialScale: 2),
      2,
    );
    expect(
      computeReaderDoubleTapZoomTarget(currentScale: 1, initialScale: null),
      isNull,
    );
  });

  test('reader long press zoom flag tolerates synced malformed settings', () {
    expect(shouldEnableReaderLongPressZoom(true), isTrue);
    expect(shouldEnableReaderLongPressZoom(false), isFalse);
    expect(shouldEnableReaderLongPressZoom('true'), isTrue);
    expect(shouldEnableReaderLongPressZoom('false'), isFalse);
    expect(shouldEnableReaderLongPressZoom(1), isTrue);
    expect(shouldEnableReaderLongPressZoom(0), isFalse);
    expect(shouldEnableReaderLongPressZoom('bad'), isTrue);
    expect(shouldEnableReaderLongPressZoom(['false']), isTrue);
    expect(shouldEnableReaderLongPressZoom(null), isTrue);
  });

  test('reader status info flag tolerates synced malformed settings', () {
    expect(shouldShowReaderClockAndBatteryInfo(true), isTrue);
    expect(shouldShowReaderClockAndBatteryInfo(false), isFalse);
    expect(shouldShowReaderClockAndBatteryInfo('true'), isTrue);
    expect(shouldShowReaderClockAndBatteryInfo('false'), isFalse);
    expect(shouldShowReaderClockAndBatteryInfo(1), isTrue);
    expect(shouldShowReaderClockAndBatteryInfo(0), isFalse);
    expect(shouldShowReaderClockAndBatteryInfo('bad'), isTrue);
    expect(shouldShowReaderClockAndBatteryInfo(['false']), isTrue);
    expect(shouldShowReaderClockAndBatteryInfo(null), isTrue);
  });

  test('reader system status bar flag tolerates synced malformed settings', () {
    expect(shouldShowReaderSystemStatusBar(true), isTrue);
    expect(shouldShowReaderSystemStatusBar(false), isFalse);
    expect(shouldShowReaderSystemStatusBar('true'), isTrue);
    expect(shouldShowReaderSystemStatusBar('false'), isFalse);
    expect(shouldShowReaderSystemStatusBar(1), isTrue);
    expect(shouldShowReaderSystemStatusBar(0), isFalse);
    expect(shouldShowReaderSystemStatusBar('bad'), isFalse);
    expect(shouldShowReaderSystemStatusBar(['true']), isFalse);
    expect(shouldShowReaderSystemStatusBar(null), isFalse);
  });

  test('reader volume key flag tolerates synced malformed settings', () {
    expect(shouldEnableReaderVolumeKey(true), isTrue);
    expect(shouldEnableReaderVolumeKey(false), isFalse);
    expect(shouldEnableReaderVolumeKey('true'), isTrue);
    expect(shouldEnableReaderVolumeKey('false'), isFalse);
    expect(shouldEnableReaderVolumeKey(1), isTrue);
    expect(shouldEnableReaderVolumeKey(0), isFalse);
    expect(shouldEnableReaderVolumeKey('bad'), isTrue);
    expect(shouldEnableReaderVolumeKey(['false']), isTrue);
    expect(shouldEnableReaderVolumeKey(null), isTrue);
  });

  test('reader page animation flag tolerates synced malformed settings', () {
    expect(shouldEnableReaderPageAnimation(true), isTrue);
    expect(shouldEnableReaderPageAnimation(false), isFalse);
    expect(shouldEnableReaderPageAnimation('true'), isTrue);
    expect(shouldEnableReaderPageAnimation('false'), isFalse);
    expect(shouldEnableReaderPageAnimation(1), isTrue);
    expect(shouldEnableReaderPageAnimation(0), isFalse);
    expect(shouldEnableReaderPageAnimation('bad'), isTrue);
    expect(shouldEnableReaderPageAnimation(['false']), isTrue);
    expect(shouldEnableReaderPageAnimation(null), isTrue);
  });

  test('reader image width limit flag tolerates synced malformed settings', () {
    expect(shouldLimitReaderImageWidth(true), isTrue);
    expect(shouldLimitReaderImageWidth(false), isFalse);
    expect(shouldLimitReaderImageWidth('true'), isTrue);
    expect(shouldLimitReaderImageWidth('false'), isFalse);
    expect(shouldLimitReaderImageWidth(1), isTrue);
    expect(shouldLimitReaderImageWidth(0), isFalse);
    expect(shouldLimitReaderImageWidth('bad'), isTrue);
    expect(shouldLimitReaderImageWidth(['false']), isTrue);
    expect(shouldLimitReaderImageWidth(null), isTrue);
  });

  test('single image first page flag tolerates synced malformed settings', () {
    expect(shouldShowSingleImageOnFirstPage(true), isTrue);
    expect(shouldShowSingleImageOnFirstPage(false), isFalse);
    expect(shouldShowSingleImageOnFirstPage('true'), isTrue);
    expect(shouldShowSingleImageOnFirstPage('false'), isFalse);
    expect(shouldShowSingleImageOnFirstPage(1), isTrue);
    expect(shouldShowSingleImageOnFirstPage(0), isFalse);
    expect(shouldShowSingleImageOnFirstPage('bad'), isFalse);
    expect(shouldShowSingleImageOnFirstPage(['true']), isFalse);
    expect(shouldShowSingleImageOnFirstPage(null), isFalse);
  });

  test('reader images per page tolerates synced malformed settings', () {
    expect(normalizeReaderImagesPerPage(1), 1);
    expect(normalizeReaderImagesPerPage(3), 3);
    expect(normalizeReaderImagesPerPage('4'), 4);
    expect(normalizeReaderImagesPerPage(0), 1);
    expect(normalizeReaderImagesPerPage(-1), 1);
    expect(normalizeReaderImagesPerPage(99), 5);
    expect(normalizeReaderImagesPerPage('bad'), 1);
    expect(normalizeReaderImagesPerPage(['2']), 1);
    expect(normalizeReaderImagesPerPage(null), 1);
  });

  test('reader mode key tolerates synced malformed settings', () {
    expect(
      ReaderMode.fromKey('continuousTopToBottom'),
      ReaderMode.continuousTopToBottom,
    );
    expect(ReaderMode.fromKey('bad'), ReaderMode.galleryLeftToRight);
    expect(ReaderMode.fromKey(1), ReaderMode.galleryLeftToRight);
    expect(
      ReaderMode.fromKey(['galleryRightToLeft']),
      ReaderMode.galleryLeftToRight,
    );
    expect(ReaderMode.fromKey(null), ReaderMode.galleryLeftToRight);
  });

  test('auto page turning interval tolerates synced malformed settings', () {
    expect(normalizeAutoPageTurningIntervalSeconds(1), 1);
    expect(normalizeAutoPageTurningIntervalSeconds(5), 5);
    expect(normalizeAutoPageTurningIntervalSeconds('10'), 10);
    expect(normalizeAutoPageTurningIntervalSeconds(0), 1);
    expect(normalizeAutoPageTurningIntervalSeconds(-1), 1);
    expect(normalizeAutoPageTurningIntervalSeconds(99), 20);
    expect(normalizeAutoPageTurningIntervalSeconds('bad'), 5);
    expect(normalizeAutoPageTurningIntervalSeconds(['5']), 5);
    expect(normalizeAutoPageTurningIntervalSeconds(null), 5);
  });

  test(
    'auto page turning clears active state when the last page is reached',
    () {
      final controller = AutoPageTurningController();
      late void Function(Timer) tick;
      final timer = _FakeTimer();
      var pageTurns = 0;
      var stopped = 0;

      controller.start(
        interval: const Duration(seconds: 1),
        shouldStop: () => true,
        onNextPage: () => pageTurns++,
        onStopped: () => stopped++,
        timerFactory: (_, callback) {
          tick = callback;
          return timer;
        },
      );
      expect(controller.isActive, isTrue);

      tick(timer);

      expect(controller.isActive, isFalse);
      expect(timer.isActive, isFalse);
      expect(pageTurns, 0);
      expect(stopped, 1);
    },
  );

  test('comic image stream events require mounted matching stream', () {
    expect(
      shouldHandleComicImageStreamEvent(
        mounted: true,
        streamKey: 'current',
        currentStreamKey: 'current',
      ),
      isTrue,
    );
    expect(
      shouldHandleComicImageStreamEvent(
        mounted: false,
        streamKey: 'current',
        currentStreamKey: 'current',
      ),
      isFalse,
    );
    expect(
      shouldHandleComicImageStreamEvent(
        mounted: true,
        streamKey: 'old',
        currentStreamKey: 'new',
      ),
      isFalse,
    );
  });

  test('left-to-right mode maps left and right edge taps to prev/next', () {
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: true,
        reverseTapToTurnPages: false,
        modeKey: 'galleryLeftToRight',
        viewportSize: viewport,
        location: const Offset(50, 1000),
      ),
      ReaderTapNavigationAction.previous,
    );
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: true,
        reverseTapToTurnPages: false,
        modeKey: 'galleryLeftToRight',
        viewportSize: viewport,
        location: const Offset(950, 1000),
      ),
      ReaderTapNavigationAction.next,
    );
  });

  test('right-to-left mode inverts horizontal edge taps', () {
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: true,
        reverseTapToTurnPages: false,
        modeKey: 'galleryRightToLeft',
        viewportSize: viewport,
        location: const Offset(50, 1000),
      ),
      ReaderTapNavigationAction.next,
    );
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: true,
        reverseTapToTurnPages: false,
        modeKey: 'galleryRightToLeft',
        viewportSize: viewport,
        location: const Offset(950, 1000),
      ),
      ReaderTapNavigationAction.previous,
    );
  });

  test('top-to-bottom mode uses top and bottom edge taps', () {
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: true,
        reverseTapToTurnPages: false,
        modeKey: 'continuousTopToBottom',
        viewportSize: viewport,
        location: const Offset(500, 100),
      ),
      ReaderTapNavigationAction.previous,
    );
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: true,
        reverseTapToTurnPages: false,
        modeKey: 'continuousTopToBottom',
        viewportSize: viewport,
        location: const Offset(500, 1900),
      ),
      ReaderTapNavigationAction.next,
    );
  });

  test('reverseTapToTurnPages swaps the computed action', () {
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: true,
        reverseTapToTurnPages: true,
        modeKey: 'galleryLeftToRight',
        viewportSize: viewport,
        location: const Offset(50, 1000),
      ),
      ReaderTapNavigationAction.next,
    );
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: true,
        reverseTapToTurnPages: true,
        modeKey: 'continuousTopToBottom',
        viewportSize: viewport,
        location: const Offset(500, 1900),
      ),
      ReaderTapNavigationAction.previous,
    );
  });

  test('center taps or disabled tap-turn return no navigation action', () {
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: true,
        reverseTapToTurnPages: false,
        modeKey: 'galleryLeftToRight',
        viewportSize: viewport,
        location: const Offset(500, 1000),
      ),
      isNull,
    );
    expect(
      computeReaderTapNavigationAction(
        enableTapToTurnPages: false,
        reverseTapToTurnPages: false,
        modeKey: 'galleryLeftToRight',
        viewportSize: viewport,
        location: const Offset(50, 1000),
      ),
      isNull,
    );
  });

  test('toolbar suppression only applies before the deadline', () {
    final now = DateTime(2026, 5, 17, 12, 0, 0);
    expect(shouldSuppressReaderToolbarTap(null, now: now), isFalse);
    expect(
      shouldSuppressReaderToolbarTap(
        now.add(const Duration(milliseconds: 1)),
        now: now,
      ),
      isTrue,
    );
    expect(
      shouldSuppressReaderToolbarTap(
        now.subtract(const Duration(milliseconds: 1)),
        now: now,
      ),
      isFalse,
    );
  });

  test('scroll-end suppression outlasts double-tap recognition delay', () {
    expect(
      kReaderToolbarTapSuppressAfterScrollEnd,
      greaterThan(kReaderDoubleTapMaxTime),
    );
  });

  test('tap-up suppression still blocks toolbar after suppression expires', () {
    expect(
      shouldOpenReaderToolbar(
        tapHandledByImageView: false,
        isToolbarOpen: false,
        isOnChapterCommentsPage: false,
        suppressToolbarFromTapUp: true,
        suppressToolbarNow: false,
      ),
      isFalse,
    );
  });

  test('toolbar opens only when no suppression or other guard applies', () {
    expect(
      shouldOpenReaderToolbar(
        tapHandledByImageView: false,
        isToolbarOpen: false,
        isOnChapterCommentsPage: false,
      ),
      isTrue,
    );
    expect(
      shouldOpenReaderToolbar(
        tapHandledByImageView: true,
        isToolbarOpen: false,
        isOnChapterCommentsPage: false,
      ),
      isFalse,
    );
    expect(
      shouldOpenReaderToolbar(
        tapHandledByImageView: false,
        isToolbarOpen: true,
        isOnChapterCommentsPage: false,
      ),
      isTrue,
    );
    expect(
      shouldOpenReaderToolbar(
        tapHandledByImageView: false,
        isToolbarOpen: false,
        isOnChapterCommentsPage: true,
      ),
      isFalse,
    );
  });

  test('delayed gesture callbacks require mounted matching state', () {
    expect(
      shouldRunReaderLongPressCallback(
        mounted: true,
        lastPointer: 7,
        eventPointer: 7,
        fingers: 1,
      ),
      isTrue,
    );
    expect(
      shouldRunReaderLongPressCallback(
        mounted: false,
        lastPointer: 7,
        eventPointer: 7,
        fingers: 1,
      ),
      isFalse,
    );
    expect(
      shouldRunReaderLongPressCallback(
        mounted: true,
        lastPointer: 8,
        eventPointer: 7,
        fingers: 1,
      ),
      isFalse,
    );
    expect(
      shouldRunReaderLongPressCallback(
        mounted: true,
        lastPointer: 7,
        eventPointer: 7,
        fingers: 2,
      ),
      isFalse,
    );

    final pendingTap = Object();
    expect(
      shouldRunReaderPendingTapCallback(
        mounted: true,
        currentPendingTap: pendingTap,
        pendingTap: pendingTap,
      ),
      isTrue,
    );
    expect(
      shouldRunReaderPendingTapCallback(
        mounted: false,
        currentPendingTap: pendingTap,
        pendingTap: pendingTap,
      ),
      isFalse,
    );
    expect(
      shouldRunReaderPendingTapCallback(
        mounted: true,
        currentPendingTap: Object(),
        pendingTap: pendingTap,
      ),
      isFalse,
    );
  });

  test(
    'pointer tracking ignores sentinel down events and clamps end count',
    () {
      expect(shouldTrackReaderPointerDown(Offset.zero), isFalse);
      expect(shouldTrackReaderPointerDown(const Offset(1, 0)), isTrue);

      expect(readerPointerCountAfterPointerEnd(2), 1);
      expect(readerPointerCountAfterPointerEnd(1), 0);
      expect(readerPointerCountAfterPointerEnd(0), 0);
      expect(readerPointerCountAfterPointerEnd(-1), 0);
    },
  );
}

class _FakeTimer implements Timer {
  bool _isActive = true;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => 0;

  @override
  void cancel() {
    _isActive = false;
  }
}
