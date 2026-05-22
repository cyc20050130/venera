import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  tearDown(() {
    ReaderWithLoading.debugReaderBuilder = null;
  });

  test(
    'requested chapter group overrides history group when opening reader',
    () {
      expect(
        resolveReaderInitialChapterGroup(requestedGroup: 3, historyGroup: 1),
        3,
      );
    },
  );

  test('history group remains the fallback when request group is absent', () {
    expect(
      resolveReaderInitialChapterGroup(requestedGroup: null, historyGroup: 2),
      2,
    );
  });

  testWidgets('reader shell appears before reader content mounts', (
    tester,
  ) async {
    ReaderWithLoading.debugReaderBuilder = (data) => const Text('reader-ready');
    final seed = ReaderProps(
      type: ComicType.local,
      cid: 'comic-1',
      name: 'Naruto',
      chapters: null,
      history: History.fromMap({
        'type': ComicType.local.value,
        'sourceKey': 'local',
        'id': 'comic-1',
        'title': 'Naruto',
        'subtitle': '',
        'cover': '',
        'time': DateTime(2026).millisecondsSinceEpoch,
        'ep': 1,
        'page': 1,
        'max_page': 0,
        'readEpisode': const <String>[],
      }),
      author: 'author',
      tags: const ['tag'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              context.to(
                () => ReaderWithLoading(
                  id: 'comic-1',
                  sourceKey: 'local',
                  seed: seed,
                ),
                allowSnapshotting: false,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();

    expect(find.text('正在打开阅读器'), findsOneWidget);
    expect(find.text('reader-ready'), findsNothing);

    await tester.pumpAndSettle();

    expect(find.text('reader-ready'), findsOneWidget);
  });
}
