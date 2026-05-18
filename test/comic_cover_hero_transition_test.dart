import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';

void main() {
  test(
    'resolveComicPageCoverUrl prefers transition cover before hero settles',
    () {
      expect(
        resolveComicPageCoverUrl(
          isHeroTransitionSettled: false,
          transitionCover: 'entry-cover',
          detailCover: 'detail-cover',
        ),
        'entry-cover',
      );

      expect(
        resolveComicPageCoverUrl(
          isHeroTransitionSettled: true,
          transitionCover: 'entry-cover',
          detailCover: 'detail-cover',
        ),
        'detail-cover',
      );

      expect(
        resolveComicPageCoverUrl(
          isHeroTransitionSettled: false,
          transitionCover: null,
          detailCover: 'detail-cover',
        ),
        'detail-cover',
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
}

const _kTransparentImageBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg==';
