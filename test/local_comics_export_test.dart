import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/local_archive.dart';
import 'package:venera/pages/local_comics_page.dart';

void main() {
  test('normalizeLocalComicsSortType tolerates malformed implicit data', () {
    expect(normalizeLocalComicsSortType(null), LocalSortType.name);
    expect(normalizeLocalComicsSortType('name'), LocalSortType.name);
    expect(normalizeLocalComicsSortType('time_asc'), LocalSortType.timeAsc);
    expect(normalizeLocalComicsSortType('time_desc'), LocalSortType.timeDesc);
    expect(normalizeLocalComicsSortType('bad'), LocalSortType.name);
    expect(normalizeLocalComicsSortType(1), LocalSortType.name);
    expect(normalizeLocalComicsSortType(['time_desc']), LocalSortType.name);
  });

  test('local comics export result only applies while mounted and active', () {
    expect(
      shouldApplyLocalComicsExportResult(mounted: true, canceled: false),
      isTrue,
    );
    expect(
      shouldApplyLocalComicsExportResult(mounted: false, canceled: false),
      isFalse,
    );
    expect(
      shouldApplyLocalComicsExportResult(mounted: true, canceled: true),
      isFalse,
    );
  });

  test('local comics export uses operation scoped cache paths', () {
    expect(
      buildComicsExportDirectory('cache', 'op-1'),
      '${Directory('cache').path}${Platform.pathSeparator}comics_export-op-1',
    );
    expect(
      buildComicsExportArchivePath('cache', 'op-1'),
      '${Directory('cache').path}${Platform.pathSeparator}comics_export-op-1.zip',
    );
  });

  test('archive UI chooses a safe primary action for every storage state', () {
    expect(localArchiveUiActionForState(null), LocalArchiveUiAction.compress);
    expect(
      localArchiveUiActionForState(LocalStorageState.loose),
      LocalArchiveUiAction.compress,
    );
    expect(
      localArchiveUiActionForState(LocalStorageState.archived),
      LocalArchiveUiAction.restore,
    );
    expect(
      localArchiveUiActionForState(LocalStorageState.expanded),
      LocalArchiveUiAction.releaseExtracted,
    );
    expect(
      localArchiveUiActionForState(LocalStorageState.dirty),
      LocalArchiveUiAction.recompress,
    );
    expect(
      localArchiveUiActionForState(LocalStorageState.error),
      LocalArchiveUiAction.none,
    );
    expect(
      localArchiveUiActionForState(LocalStorageState.missing),
      LocalArchiveUiAction.none,
    );
  });

  test('archive badges expose persistent and active states', () {
    expect(localArchiveBadgeKey(null), isNull);
    expect(localArchiveBadgeKey(LocalStorageState.archived), 'Archived');
    expect(localArchiveBadgeKey(LocalStorageState.expanded), 'Expanded');
    expect(localArchiveBadgeKey(LocalStorageState.dirty), 'Archive modified');
    expect(localArchiveBadgeKey(LocalStorageState.error), 'Archive error');
    expect(
      localArchiveBadgeKey(LocalStorageState.archived, operationRunning: true),
      'Archiving',
    );
  });

  test('archive UI rejects comics outside the managed library', () {
    final root = p.join(Directory.current.path, 'local-library');
    expect(
      isLocalArchivePathManaged(
        libraryPath: root,
        comicPath: p.join(root, 'comic-a'),
      ),
      isTrue,
    );
    expect(
      isLocalArchivePathManaged(libraryPath: root, comicPath: root),
      isFalse,
    );
    expect(
      isLocalArchivePathManaged(
        libraryPath: root,
        comicPath: p.join(Directory.current.path, 'external', 'comic-a'),
      ),
      isFalse,
    );
    expect(
      isLocalArchivePathManaged(
        libraryPath: root,
        comicPath: p.join('$root-sibling', 'comic-a'),
      ),
      isFalse,
    );
  });

  test('archive operation progress reserves time for cleanup', () {
    expect(
      localArchiveOperationProgress(
        const LocalArchiveProgress(
          operation: LocalArchiveOperation.inspect,
          completedFiles: 5,
          totalFiles: 10,
        ),
      ),
      closeTo(0.1, 0.0001),
    );
    expect(
      localArchiveOperationProgress(
        const LocalArchiveProgress(
          operation: LocalArchiveOperation.compress,
          completedFiles: 5,
          totalFiles: 10,
        ),
      ),
      closeTo(0.5, 0.0001),
    );
    expect(
      localArchiveOperationProgress(
        const LocalArchiveProgress(
          operation: LocalArchiveOperation.cleanup,
          completedFiles: 5,
          totalFiles: 10,
        ),
      ),
      closeTo(0.9, 0.0001),
    );
  });

  test('bulk archive failures expose grouped root causes', () {
    expect(
      summarizeLocalArchiveFailures([
        const LocalArchiveException('writer unavailable'),
        const LocalArchiveException('writer unavailable'),
        const LocalArchiveException('unsafe path'),
      ]),
      '2× writer unavailable; 1× unsafe path',
    );
  });
}
