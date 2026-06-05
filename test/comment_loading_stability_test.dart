import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  test('comment load guards avoid duplicate in-flight requests', () {
    expect(shouldStartCommentLoad(loading: true, inFlight: false), isTrue);
    expect(shouldStartCommentLoad(loading: true, inFlight: true), isFalse);
    expect(shouldStartCommentLoad(loading: false, inFlight: false), isFalse);
  });

  test('comment action results require mounted current request', () {
    expect(
      shouldApplyCommentActionResult(
        mounted: true,
        requestId: 2,
        activeRequestId: 2,
      ),
      isTrue,
    );
    expect(
      shouldApplyCommentActionResult(
        mounted: false,
        requestId: 2,
        activeRequestId: 2,
      ),
      isFalse,
    );
    expect(
      shouldApplyCommentActionResult(
        mounted: true,
        requestId: 1,
        activeRequestId: 2,
      ),
      isFalse,
    );
  });

  test('comment vote status resolver matches action semantics', () {
    expect(resolveCommentVoteStatus(isUp: true, isCancel: false), 1);
    expect(resolveCommentVoteStatus(isUp: false, isCancel: false), -1);
    expect(resolveCommentVoteStatus(isUp: true, isCancel: true), 0);
    expect(resolveCommentVoteStatus(isUp: false, isCancel: true), 0);
  });

  test('comment pagination max page accepts numeric source values', () {
    expect(normalizeLoadingMaxPage('5'), 5);
    expect(normalizeLoadingMaxPage(6.2), 6);
    expect(normalizeLoadingMaxPage('bad'), isNull);
  });

  test('chapter comment load guards avoid duplicate in-flight requests', () {
    expect(
      shouldStartChapterCommentLoad(loading: true, inFlight: false),
      isTrue,
    );
    expect(
      shouldStartChapterCommentLoad(loading: true, inFlight: true),
      isFalse,
    );
    expect(
      shouldStartChapterCommentLoad(loading: false, inFlight: false),
      isFalse,
    );
  });

  test('chapter comment action results require mounted current request', () {
    expect(
      shouldApplyChapterCommentActionResult(
        mounted: true,
        requestId: 2,
        activeRequestId: 2,
      ),
      isTrue,
    );
    expect(
      shouldApplyChapterCommentActionResult(
        mounted: false,
        requestId: 2,
        activeRequestId: 2,
      ),
      isFalse,
    );
    expect(
      shouldApplyChapterCommentActionResult(
        mounted: true,
        requestId: 1,
        activeRequestId: 2,
      ),
      isFalse,
    );
  });

  test('chapter comment vote status resolver matches action semantics', () {
    expect(resolveChapterCommentVoteStatus(isUp: true, isCancel: false), 1);
    expect(resolveChapterCommentVoteStatus(isUp: false, isCancel: false), -1);
    expect(resolveChapterCommentVoteStatus(isUp: true, isCancel: true), 0);
    expect(resolveChapterCommentVoteStatus(isUp: false, isCancel: true), 0);
  });

  testWidgets('rich comment content treats empty tags as text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(child: RichCommentContent(text: '<   >hello</   >')),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('hello'), findsOneWidget);
  });
}
