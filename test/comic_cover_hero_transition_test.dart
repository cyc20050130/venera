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
}

const _kTransparentImageBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg==';
