import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/download_chapter_retention.dart';

void main() {
  DownloadChapterRetentionKey key(
    String comicId,
    int comicType,
    String chapterId,
  ) {
    return DownloadChapterRetentionKey(
      comicId: comicId,
      comicType: comicType,
      chapterId: chapterId,
    );
  }

  test('selectExcess returns the oldest finished chapters beyond the limit', () {
    final tracker = DownloadChapterRetentionTracker();

    tracker.markFinishedRead(
      key('comic-1', 1, 'chapter-1'),
      DateTime(2025, 1, 1, 12),
    );
    tracker.markFinishedRead(
      key('comic-2', 2, 'chapter-5'),
      DateTime(2025, 1, 2, 12),
    );
    tracker.markFinishedRead(
      key('comic-3', 3, 'chapter-2'),
      DateTime(2025, 1, 3, 12),
    );

    final excess = tracker.selectExcess(limit: 2);

    expect(excess, hasLength(1));
    expect(excess.single.key, key('comic-1', 1, 'chapter-1'));
  });

  test('markFinishedRead refreshes timestamp when a chapter is read again', () {
    final tracker = DownloadChapterRetentionTracker();
    final rereadKey = key('comic-1', 1, 'chapter-1');

    tracker.markFinishedRead(
      rereadKey,
      DateTime(2025, 1, 1, 12),
    );
    tracker.markFinishedRead(
      key('comic-2', 2, 'chapter-5'),
      DateTime(2025, 1, 2, 12),
    );
    tracker.markFinishedRead(
      rereadKey,
      DateTime(2025, 1, 3, 12),
    );

    final excess = tracker.selectExcess(limit: 1);

    expect(excess, hasLength(1));
    expect(excess.single.key, key('comic-2', 2, 'chapter-5'));
  });

  test('selectExcess keeps all chapters when count does not exceed the limit', () {
    final tracker = DownloadChapterRetentionTracker();

    tracker.markFinishedRead(
      key('comic-1', 1, 'chapter-1'),
      DateTime(2025, 1, 1, 12),
    );
    tracker.markFinishedRead(
      key('comic-2', 2, 'chapter-5'),
      DateTime(2025, 1, 2, 12),
    );

    final excess = tracker.selectExcess(limit: 2);

    expect(excess, isEmpty);
  });

  test('resolveReadChapterIds maps flat history episodes to chapter ids', () {
    final chapters = ComicChapters({
      'chapter-a': 'Chapter A',
      'chapter-b': 'Chapter B',
      'chapter-c': 'Chapter C',
    });

    final resolved = resolveReadChapterIds(
      chapters,
      {'1', '3', '999', 'invalid'},
    );

    expect(resolved, {'chapter-a', 'chapter-c'});
  });

  test('resolveReadChapterIds maps grouped history episodes to chapter ids', () {
    final chapters = ComicChapters.grouped({
      'Volume 1': {
        'chapter-a': 'Chapter A',
        'chapter-b': 'Chapter B',
      },
      'Volume 2': {
        'chapter-c': 'Chapter C',
      },
    });

    final resolved = resolveReadChapterIds(
      chapters,
      {'1-2', '2-1', '2-9', 'bad-format'},
    );

    expect(resolved, {'chapter-b', 'chapter-c'});
  });

  test('buildBackfillEntries only keeps downloaded flat chapters', () {
    final chapters = ComicChapters({
      'chapter-a': 'Chapter A',
      'chapter-b': 'Chapter B',
      'chapter-c': 'Chapter C',
    });
    final finishedReadAt = DateTime(2025, 1, 4, 12);

    final entries = buildBackfillEntries(
      comicId: 'comic-1',
      comicType: 1,
      chapters: chapters,
      downloadedChapterIds: const ['chapter-a', 'chapter-c'],
      readEpisodes: {'1', '2', '3'},
      finishedReadAt: finishedReadAt,
    );

    expect(entries.map((e) => e.key.chapterId).toSet(), {
      'chapter-a',
      'chapter-c',
    });
    expect(entries.every((e) => e.finishedReadAt == finishedReadAt), isTrue);
  });

  test('buildBackfillEntries only keeps downloaded grouped chapters', () {
    final chapters = ComicChapters.grouped({
      'Volume 1': {
        'chapter-a': 'Chapter A',
        'chapter-b': 'Chapter B',
      },
      'Volume 2': {
        'chapter-c': 'Chapter C',
        'chapter-d': 'Chapter D',
      },
    });

    final entries = buildBackfillEntries(
      comicId: 'comic-2',
      comicType: 2,
      chapters: chapters,
      downloadedChapterIds: const ['chapter-b', 'chapter-d'],
      readEpisodes: {'1-1', '1-2', '2-2'},
      finishedReadAt: DateTime(2025, 1, 5, 12),
    );

    expect(entries.map((e) => e.key.chapterId).toSet(), {
      'chapter-b',
      'chapter-d',
    });
  });

  test('validateRetentionEntries separates valid and stale chapter records', () {
    final entries = [
      DownloadChapterRetentionEntry(
        key: key('comic-1', 1, 'chapter-a'),
        finishedReadAt: DateTime(2025, 1, 1, 12),
      ),
      DownloadChapterRetentionEntry(
        key: key('comic-1', 1, 'chapter-b'),
        finishedReadAt: DateTime(2025, 1, 2, 12),
      ),
      DownloadChapterRetentionEntry(
        key: key('comic-2', 2, 'chapter-c'),
        finishedReadAt: DateTime(2025, 1, 3, 12),
      ),
    ];

    final validation = validateRetentionEntries(
      entries,
      isAvailable: (entryKey) =>
          entryKey.chapterId == 'chapter-a' || entryKey.chapterId == 'chapter-c',
    );

    expect(validation.validEntries.map((e) => e.key.chapterId).toList(), [
      'chapter-a',
      'chapter-c',
    ]);
    expect(validation.staleKeys.map((e) => e.chapterId).toList(), [
      'chapter-b',
    ]);
  });

  test('groupEntriesByComic batches chapters by comic id and type', () {
    final grouped = groupEntriesByComic([
      DownloadChapterRetentionEntry(
        key: key('comic-1', 1, 'chapter-a'),
        finishedReadAt: DateTime(2025, 1, 1, 12),
      ),
      DownloadChapterRetentionEntry(
        key: key('comic-1', 1, 'chapter-b'),
        finishedReadAt: DateTime(2025, 1, 2, 12),
      ),
      DownloadChapterRetentionEntry(
        key: key('comic-2', 2, 'chapter-c'),
        finishedReadAt: DateTime(2025, 1, 3, 12),
      ),
    ]);

    expect(grouped, hasLength(2));
    expect(grouped[key('comic-1', 1, '')], ['chapter-a', 'chapter-b']);
    expect(grouped[key('comic-2', 2, '')], ['chapter-c']);
  });
}
