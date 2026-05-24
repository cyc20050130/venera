import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/gesture_logic.dart';

void main() {
  const viewport = Size(1000, 2000);

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
    expect(shouldSuppressReaderTapTurn(null, now: now), isFalse);
    expect(
      shouldSuppressReaderToolbarTap(
        now.add(const Duration(milliseconds: 1)),
        now: now,
      ),
      isTrue,
    );
    expect(
      shouldSuppressReaderTapTurn(
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

  test(
    'center taps can still open toolbar when only tap-turn suppression exists',
    () {
      expect(
        shouldOpenReaderToolbar(
          tapHandledByImageView: false,
          isToolbarOpen: false,
          isOnChapterCommentsPage: false,
          suppressToolbarFromTapUp: false,
          suppressToolbarNow: false,
          isCentralToolbarTap: true,
        ),
        isTrue,
      );
    },
  );

  test('edge tap suppression does not fallback into opening toolbar', () {
    expect(
      shouldOpenReaderToolbar(
        tapHandledByImageView: false,
        isToolbarOpen: false,
        isOnChapterCommentsPage: false,
        isCentralToolbarTap: false,
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
}
