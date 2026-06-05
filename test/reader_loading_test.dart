import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() async {
    await AppTranslation.init();
  });

  tearDown(() {
    ReaderWithLoading.debugReaderBuilder = null;
  });

  test('canReaderSwitchChapter ignores same chapter and invalid targets', () {
    expect(
      canReaderSwitchChapter(
        currentChapter: 3,
        targetChapter: 3,
        maxChapter: 5,
        isLoading: false,
      ),
      isFalse,
    );
    expect(
      canReaderSwitchChapter(
        currentChapter: 3,
        targetChapter: 0,
        maxChapter: 5,
        isLoading: false,
      ),
      isFalse,
    );
    expect(
      canReaderSwitchChapter(
        currentChapter: 3,
        targetChapter: 6,
        maxChapter: 5,
        isLoading: false,
      ),
      isFalse,
    );
    expect(
      canReaderSwitchChapter(
        currentChapter: 3,
        targetChapter: 4,
        maxChapter: 5,
        isLoading: true,
      ),
      isFalse,
    );
    expect(
      canReaderSwitchChapter(
        currentChapter: 3,
        targetChapter: 4,
        maxChapter: 5,
        isLoading: false,
      ),
      isTrue,
    );
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

  test('normalizeReaderInitialChapter clamps stale flat chapter history', () {
    final chapters = ComicChapters({
      '1': 'Chapter 1',
      '2': 'Chapter 2',
      '3': 'Chapter 3',
    });

    expect(
      normalizeReaderInitialChapter(
        requestedChapter: 2,
        requestedGroup: null,
        chapters: chapters,
      ),
      2,
    );
    expect(
      normalizeReaderInitialChapter(
        requestedChapter: 99,
        requestedGroup: null,
        chapters: chapters,
      ),
      3,
    );
    expect(
      normalizeReaderInitialChapter(
        requestedChapter: -4,
        requestedGroup: null,
        chapters: chapters,
      ),
      1,
    );
    expect(
      normalizeReaderInitialChapter(
        requestedChapter: 7,
        requestedGroup: null,
        chapters: null,
      ),
      1,
    );
  });

  test('normalizeReaderInitialChapter resolves grouped chapter safely', () {
    final chapters = ComicChapters.grouped({
      'A': {'a1': 'A1', 'a2': 'A2'},
      'B': {'b1': 'B1', 'b2': 'B2', 'b3': 'B3'},
    });

    expect(
      normalizeReaderInitialChapter(
        requestedChapter: 2,
        requestedGroup: 2,
        chapters: chapters,
      ),
      4,
    );
    expect(
      normalizeReaderInitialChapter(
        requestedChapter: 99,
        requestedGroup: 2,
        chapters: chapters,
      ),
      5,
    );
    expect(
      normalizeReaderInitialChapter(
        requestedChapter: 1,
        requestedGroup: 9,
        chapters: chapters,
      ),
      1,
    );
    expect(
      normalizeReaderInitialChapter(
        requestedChapter: 2,
        requestedGroup: 2,
        chapters: ComicChapters({'1': 'Chapter 1', '2': 'Chapter 2'}),
      ),
      2,
    );
  });

  test('resolveGroupedReaderChapterPosition skips empty groups safely', () {
    final chapters = ComicChapters.grouped({
      'Empty': {},
      'A': {'a1': 'A1', 'a2': 'A2'},
      'Also Empty': {},
      'B': {'b1': 'B1'},
    });

    expect(
      resolveGroupedReaderChapterPosition(chapters: chapters, chapter: 1),
      (groupIndex: 1, chapterInGroup: 1),
    );
    expect(
      resolveGroupedReaderChapterPosition(chapters: chapters, chapter: 3),
      (groupIndex: 3, chapterInGroup: 1),
    );
    expect(
      resolveGroupedReaderChapterPosition(chapters: chapters, chapter: 4),
      isNull,
    );
    expect(
      resolveGroupedReaderChapterPosition(
        chapters: ComicChapters.grouped({}),
        chapter: 1,
      ),
      isNull,
    );
  });

  test('reader deferred work keeps initial interactive window clear', () {
    final startedAt = DateTime(2026, 6, 2, 12);
    expect(
      computeReaderDeferredWorkRemaining(
        startedAt: startedAt,
        now: startedAt.add(const Duration(milliseconds: 500)),
        delay: const Duration(milliseconds: 1200),
      ),
      const Duration(milliseconds: 700),
    );
    expect(
      computeReaderDeferredWorkRemaining(
        startedAt: startedAt,
        now: startedAt.add(const Duration(seconds: 2)),
        delay: const Duration(milliseconds: 1200),
      ),
      Duration.zero,
    );
  });

  test('reader deferred work coalesces tasks by key', () async {
    final scheduler = ReaderDeferredWorkScheduler(
      remainingDelay: () => const Duration(milliseconds: 40),
      schedulePostFrame: (task) => task(),
    );
    final runs = <int>[];

    scheduler.run('same', () => runs.add(1));
    scheduler.run('same', () => runs.add(2));
    scheduler.run('other', () => runs.add(3));

    await Future<void>.delayed(const Duration(milliseconds: 90));

    expect(runs, [2, 3]);
    scheduler.dispose();
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

  testWidgets('reader overlay host rebuilds child when chapter shell changes', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _OverlayHostProbe()));

    expect(find.text('chapter-1'), findsOneWidget);
    expect(find.text('chapter-2'), findsNothing);

    await tester.tap(find.text('next'));
    await tester.pump();

    expect(find.text('chapter-1'), findsNothing);
    expect(find.text('chapter-2'), findsOneWidget);
  });

  testWidgets('reader image selection overlay is removed when owner disposes', (
    tester,
  ) async {
    Future<Offset?>? selectionFuture;

    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (context) => _SelectImageOverlayControllerHost(
                onFuture: (future) {
                  selectionFuture = future;
                },
              ),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('show-select-overlay'));
    await tester.pump();

    expect(selectionFuture, isNotNull);
    expect(
      find.byWidgetPredicate(_isSelectImageOverlayContent),
      findsOneWidget,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    await expectLater(selectionFuture, completion(isNull));
    expect(find.byWidgetPredicate(_isSelectImageOverlayContent), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _OverlayHostProbe extends StatefulWidget {
  const _OverlayHostProbe();

  @override
  State<_OverlayHostProbe> createState() => _OverlayHostProbeState();
}

class _OverlayHostProbeState extends State<_OverlayHostProbe> {
  int chapter = 1;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextButton(
          onPressed: () {
            setState(() {
              chapter++;
            });
          },
          child: const Text('next'),
        ),
        Expanded(
          child: buildReaderOverlayHostForTest(
            child: Center(
              child: Text('chapter-$chapter', textDirection: TextDirection.ltr),
            ),
          ),
        ),
      ],
    );
  }
}

class _SelectImageOverlayControllerHost extends StatefulWidget {
  const _SelectImageOverlayControllerHost({required this.onFuture});

  final ValueChanged<Future<Offset?>> onFuture;

  @override
  State<_SelectImageOverlayControllerHost> createState() =>
      _SelectImageOverlayControllerHostState();
}

class _SelectImageOverlayControllerHostState
    extends State<_SelectImageOverlayControllerHost> {
  late final ReaderSelectImageOverlayController controller =
      ReaderSelectImageOverlayController(
        overlayProvider: () => Overlay.of(context),
      );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(
        onPressed: () {
          widget.onFuture(controller.show());
        },
        child: const Text('show-select-overlay'),
      ),
    );
  }
}

bool _isSelectImageOverlayContent(Widget widget) {
  return widget.runtimeType.toString() == '_SelectImageOverlayContent';
}
