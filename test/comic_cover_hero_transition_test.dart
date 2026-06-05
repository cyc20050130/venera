import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app_page_route.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';

void main() {
  test(
    'buildComicCoverHeroTag distinguishes home sections for the same comic',
    () {
      expect(
        buildComicCoverHeroTag(
          scope: 'home-history',
          sourceKey: 'test-source',
          comicId: 'same-id',
          index: 0,
        ),
        isNot(
          buildComicCoverHeroTag(
            scope: 'home-local',
            sourceKey: 'test-source',
            comicId: 'same-id',
            index: 0,
          ),
        ),
      );
    },
  );

  test(
    'resolveDisplayedComicPageCoverUrl keeps transition cover until detail cover can replace it',
    () {
      expect(
        resolveDisplayedComicPageCoverUrl(
          canPromoteToDetailCover: false,
          transitionCover: 'entry-cover',
          detailCover: 'detail-cover',
        ),
        'entry-cover',
      );

      expect(
        resolveDisplayedComicPageCoverUrl(
          canPromoteToDetailCover: true,
          transitionCover: 'entry-cover',
          detailCover: 'detail-cover',
        ),
        'detail-cover',
      );

      expect(
        resolveDisplayedComicPageCoverUrl(
          canPromoteToDetailCover: false,
          transitionCover: null,
          detailCover: 'detail-cover',
        ),
        'detail-cover',
      );

      expect(
        resolveDisplayedComicPageCoverUrl(
          canPromoteToDetailCover: false,
          transitionCover: null,
          detailCover: null,
          currentCover: 'current-cover',
        ),
        'current-cover',
      );
    },
  );

  test(
    'resolveCoverDecodeDimension clamps invalid and oversized dimensions',
    () {
      expect(resolveCoverDecodeDimension(100, 2.5), 250);
      expect(resolveCoverDecodeDimension(0, 2), isNull);
      expect(resolveCoverDecodeDimension(-1, 2), isNull);
      expect(resolveCoverDecodeDimension(100, 0), isNull);
      expect(resolveCoverDecodeDimension(double.nan, 2), isNull);
      expect(resolveCoverDecodeDimension(100, double.infinity), isNull);
      expect(resolveCoverDecodeDimension(5000, 3), 4096);
    },
  );

  test('comic page cover has a stable logical decode surface', () {
    expect(comicPageCoverLogicalHeight, 144);
    expect(comicPageCoverLogicalWidth, 144 * 0.72);
  });

  test('comic thumbnails keep a bounded decode surface', () {
    expect(comicThumbnailMaxCrossAxisExtent, 200);
    expect(comicThumbnailChildAspectRatio, 0.68);
    expect(
      resolveCoverDecodeDimension(
        comicThumbnailMaxCrossAxisExtent / comicThumbnailChildAspectRatio,
        3,
      ),
      883,
    );
  });

  test('comic thumbnail parser extracts optional crop ranges', () {
    final thumbnail = parseComicThumbnailSpec(
      'https://example.test/a.jpg@x=0.1-0.9&y=0.2-0.8',
    );

    expect(thumbnail.url, 'https://example.test/a.jpg');
    expect(thumbnail.part?.x1, 0.1);
    expect(thumbnail.part?.x2, 0.9);
    expect(thumbnail.part?.y1, 0.2);
    expect(thumbnail.part?.y2, 0.8);
  });

  test('comic thumbnail parser ignores malformed crop suffixes', () {
    expect(parseComicThumbnailSpec('https://example.test/a.jpg').part, isNull);
    expect(parseComicThumbnailSpec('https://example.test/a.jpg@').part, isNull);
    expect(
      parseComicThumbnailSpec('https://example.test/a.jpg@x=bad&y=1').part,
      isNull,
    );
  });

  test('comic pagination cursor normalizes source values', () {
    expect(normalizeComicPaginationCursor('next'), 'next');
    expect(normalizeComicPaginationCursor(2), '2');
    expect(normalizeComicPaginationCursor(''), isNull);
    expect(normalizeComicPaginationCursor(null), isNull);
  });

  testWidgets(
    'AnimatedImage skips AnimatedSwitcher when first frame animation is disabled',
    (tester) async {
      final image = MemoryImage(base64Decode(_kTransparentImageBase64));

      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: AnimatedImage(
              image: image,
              width: 24,
              height: 24,
              animateOnFirstFrame: false,
            ),
          ),
        ),
      );

      expect(find.byType(AnimatedSwitcher), findsNothing);
    },
  );

  testWidgets('AnimatedImage keeps AnimatedSwitcher by default', (
    tester,
  ) async {
    final image = MemoryImage(base64Decode(_kTransparentImageBase64));

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: AnimatedImage(image: image, width: 24, height: 24),
        ),
      ),
    );

    expect(find.byType(AnimatedSwitcher), findsOneWidget);
  });

  test('AppPageRoute can disable snapshotting for hero-heavy transitions', () {
    final route = AppPageRoute<void>(
      builder: (_) => const SizedBox(),
      allowSnapshotting: false,
    );

    expect(route.allowSnapshotting, isFalse);
  });

  test('comic page opens reader with snapshotting disabled', () {
    expect(comicPageReaderAllowSnapshotting, isFalse);
  });

  testWidgets('IOSBackGestureController cancel stops user gesture once', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          key: navigatorKey,
          onGenerateRoute: (settings) =>
              MaterialPageRoute<void>(builder: (_) => const SizedBox()),
        ),
      ),
    );

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const SizedBox()),
    );
    await tester.pumpAndSettle();

    final navigator = navigatorKey.currentState!;
    final animationController = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(animationController.dispose);
    final controller = IOSBackGestureController(animationController, navigator);

    expect(navigator.userGestureInProgress, isTrue);

    controller.cancel();
    expect(navigator.userGestureInProgress, isFalse);

    controller.cancel();
    controller.dragEnd(0);
    expect(navigator.userGestureInProgress, isFalse);
    expect(tester.takeException(), isNull);
  });
}

const _kTransparentImageBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg==';
