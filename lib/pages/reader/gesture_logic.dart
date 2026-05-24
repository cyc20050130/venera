import 'package:flutter/material.dart';

enum ReaderTapNavigationAction { previous, next }

const double kReaderTapTurnPagePercent = 0.3;
const Duration kReaderDoubleTapMaxTime = Duration(milliseconds: 200);
const Duration kReaderToolbarTapSuppressDuration = Duration(milliseconds: 300);
const Duration kReaderToolbarTapSuppressAfterNavigation = Duration(
  milliseconds: 220,
);
const Duration kReaderToolbarTapSuppressAfterScrollEnd = Duration(
  milliseconds: 450,
);

ReaderTapNavigationAction? computeReaderTapNavigationAction({
  required bool enableTapToTurnPages,
  required bool reverseTapToTurnPages,
  required String modeKey,
  required Size viewportSize,
  required Offset location,
  double tapZonePercent = kReaderTapTurnPagePercent,
}) {
  if (!enableTapToTurnPages) {
    return null;
  }

  final isLeft = location.dx < viewportSize.width * tapZonePercent;
  final isRight = location.dx > viewportSize.width * (1 - tapZonePercent);
  final isTop = location.dy < viewportSize.height * tapZonePercent;
  final isBottom = location.dy > viewportSize.height * (1 - tapZonePercent);

  switch (modeKey) {
    case 'galleryLeftToRight':
    case 'continuousLeftToRight':
      if (isLeft) {
        return reverseTapToTurnPages
            ? ReaderTapNavigationAction.next
            : ReaderTapNavigationAction.previous;
      }
      if (isRight) {
        return reverseTapToTurnPages
            ? ReaderTapNavigationAction.previous
            : ReaderTapNavigationAction.next;
      }
    case 'galleryRightToLeft':
    case 'continuousRightToLeft':
      if (isLeft) {
        return reverseTapToTurnPages
            ? ReaderTapNavigationAction.previous
            : ReaderTapNavigationAction.next;
      }
      if (isRight) {
        return reverseTapToTurnPages
            ? ReaderTapNavigationAction.next
            : ReaderTapNavigationAction.previous;
      }
    case 'galleryTopToBottom':
    case 'continuousTopToBottom':
      if (isTop) {
        return reverseTapToTurnPages
            ? ReaderTapNavigationAction.next
            : ReaderTapNavigationAction.previous;
      }
      if (isBottom) {
        return reverseTapToTurnPages
            ? ReaderTapNavigationAction.previous
            : ReaderTapNavigationAction.next;
      }
  }

  return null;
}

bool shouldSuppressReaderToolbarTap(
  DateTime? suppressedUntil, {
  DateTime? now,
}) {
  if (suppressedUntil == null) {
    return false;
  }
  final currentTime = now ?? DateTime.now();
  return suppressedUntil.isAfter(currentTime);
}

bool shouldSuppressReaderTapTurn(DateTime? suppressedUntil, {DateTime? now}) {
  return shouldSuppressReaderToolbarTap(suppressedUntil, now: now);
}

bool shouldOpenReaderToolbar({
  required bool tapHandledByImageView,
  required bool isToolbarOpen,
  required bool isOnChapterCommentsPage,
  bool suppressToolbarFromTapUp = false,
  bool suppressToolbarNow = false,
  bool isCentralToolbarTap = true,
}) {
  if (tapHandledByImageView) {
    return false;
  }
  if (isToolbarOpen) {
    return true;
  }
  if (isOnChapterCommentsPage) {
    return false;
  }
  if (!isCentralToolbarTap) {
    return false;
  }
  if (suppressToolbarFromTapUp || suppressToolbarNow) {
    return false;
  }
  return true;
}
