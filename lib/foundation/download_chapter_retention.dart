import 'package:venera/foundation/comic_source/comic_source.dart';

class DownloadChapterRetentionKey {
  final String comicId;
  final int comicType;
  final String chapterId;

  const DownloadChapterRetentionKey({
    required this.comicId,
    required this.comicType,
    required this.chapterId,
  });

  @override
  bool operator ==(Object other) {
    return other is DownloadChapterRetentionKey &&
        other.comicId == comicId &&
        other.comicType == comicType &&
        other.chapterId == chapterId;
  }

  @override
  int get hashCode => Object.hash(comicId, comicType, chapterId);
}

class DownloadChapterRetentionEntry {
  final DownloadChapterRetentionKey key;
  final DateTime finishedReadAt;

  const DownloadChapterRetentionEntry({
    required this.key,
    required this.finishedReadAt,
  });
}

class DownloadChapterRetentionValidation {
  final List<DownloadChapterRetentionEntry> validEntries;
  final List<DownloadChapterRetentionKey> staleKeys;

  const DownloadChapterRetentionValidation({
    required this.validEntries,
    required this.staleKeys,
  });
}

class DownloadChapterRetentionTracker {
  final Map<DownloadChapterRetentionKey, DownloadChapterRetentionEntry> _entries;

  DownloadChapterRetentionTracker()
    : _entries = <DownloadChapterRetentionKey, DownloadChapterRetentionEntry>{};

  DownloadChapterRetentionTracker.fromEntries(
    Iterable<DownloadChapterRetentionEntry> entries,
  ) : _entries = {
         for (final entry in entries) entry.key: entry,
       };

  void markFinishedRead(DownloadChapterRetentionKey key, DateTime finishedReadAt) {
    _entries[key] = DownloadChapterRetentionEntry(
      key: key,
      finishedReadAt: finishedReadAt,
    );
  }

  List<DownloadChapterRetentionEntry> selectExcess({required int limit}) {
    if (limit < 0) {
      limit = 0;
    }
    final entries = _entries.values.toList()
      ..sort((a, b) => a.finishedReadAt.compareTo(b.finishedReadAt));
    final excessCount = entries.length - limit;
    if (excessCount <= 0) {
      return const [];
    }
    return entries.take(excessCount).toList();
  }
}

Set<String> resolveReadChapterIds(
  ComicChapters chapters,
  Set<String> readEpisodes,
) {
  final resolved = <String>{};

  if (chapters.isGrouped) {
    for (final readEpisode in readEpisodes) {
      final parts = readEpisode.split('-');
      if (parts.length != 2) {
        continue;
      }
      final groupIndex = int.tryParse(parts[0]);
      final chapterIndex = int.tryParse(parts[1]);
      if (groupIndex == null ||
          chapterIndex == null ||
          groupIndex < 1 ||
          chapterIndex < 1 ||
          groupIndex > chapters.groupCount) {
        continue;
      }
      final group = chapters.getGroupByIndex(groupIndex - 1);
      if (chapterIndex > group.length) {
        continue;
      }
      resolved.add(group.keys.elementAt(chapterIndex - 1));
    }
  } else {
    final ids = chapters.ids.toList();
    for (final readEpisode in readEpisodes) {
      final chapterIndex = int.tryParse(readEpisode);
      if (chapterIndex == null || chapterIndex < 1 || chapterIndex > ids.length) {
        continue;
      }
      resolved.add(ids[chapterIndex - 1]);
    }
  }

  return resolved;
}

List<DownloadChapterRetentionEntry> buildBackfillEntries({
  required String comicId,
  required int comicType,
  required ComicChapters chapters,
  required List<String> downloadedChapterIds,
  required Set<String> readEpisodes,
  required DateTime finishedReadAt,
}) {
  final downloaded = downloadedChapterIds.toSet();
  final readChapterIds = resolveReadChapterIds(chapters, readEpisodes)
      .where(downloaded.contains);

  return readChapterIds
      .map(
        (chapterId) => DownloadChapterRetentionEntry(
          key: DownloadChapterRetentionKey(
            comicId: comicId,
            comicType: comicType,
            chapterId: chapterId,
          ),
          finishedReadAt: finishedReadAt,
        ),
      )
      .toList();
}

DownloadChapterRetentionValidation validateRetentionEntries(
  Iterable<DownloadChapterRetentionEntry> entries, {
  required bool Function(DownloadChapterRetentionKey key) isAvailable,
}) {
  final validEntries = <DownloadChapterRetentionEntry>[];
  final staleKeys = <DownloadChapterRetentionKey>[];

  for (final entry in entries) {
    if (isAvailable(entry.key)) {
      validEntries.add(entry);
    } else {
      staleKeys.add(entry.key);
    }
  }

  return DownloadChapterRetentionValidation(
    validEntries: validEntries,
    staleKeys: staleKeys,
  );
}

Map<DownloadChapterRetentionKey, List<String>> groupEntriesByComic(
  Iterable<DownloadChapterRetentionEntry> entries,
) {
  final grouped = <DownloadChapterRetentionKey, List<String>>{};

  for (final entry in entries) {
    final comicKey = DownloadChapterRetentionKey(
      comicId: entry.key.comicId,
      comicType: entry.key.comicType,
      chapterId: '',
    );
    grouped.putIfAbsent(comicKey, () => []).add(entry.key.chapterId);
  }

  return grouped;
}
