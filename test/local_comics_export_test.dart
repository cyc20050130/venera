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
      LocalArchiveUiAction.recompress,
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
    expect(localArchiveBadgeKey(LocalStorageState.loose), 'Uncompressed');
    expect(localArchiveBadgeKey(LocalStorageState.archived), 'Compressed');
    expect(localArchiveBadgeKey(LocalStorageState.expanded), 'Compressed');
    expect(localArchiveBadgeKey(LocalStorageState.dirty), 'Uncompressed');
    expect(localArchiveBadgeKey(LocalStorageState.error), 'Compression error');
    expect(
      localArchiveBadgeKey(LocalStorageState.archived, operationRunning: true),
      'Processing',
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
      closeTo(0.075, 0.0001),
    );
    expect(
      localArchiveOperationProgress(
        const LocalArchiveProgress(
          operation: LocalArchiveOperation.compress,
          completedFiles: 5,
          totalFiles: 10,
        ),
      ),
      closeTo(0.375, 0.0001),
    );
    expect(
      localArchiveOperationProgress(
        const LocalArchiveProgress(
          operation: LocalArchiveOperation.cleanup,
          completedFiles: 5,
          totalFiles: 10,
        ),
      ),
      closeTo(0.95, 0.0001),
    );
  });

  test('archive progress and remaining time prefer byte progress', () {
    final progress = const LocalArchiveProgress(
      operation: LocalArchiveOperation.compress,
      completedFiles: 1,
      totalFiles: 10,
      completedBytes: 500,
      totalBytes: 1000,
    );
    expect(progress.fraction, 0.5);
    expect(
      estimateLocalArchiveRemaining(
        elapsed: const Duration(seconds: 10),
        progress: 0.25,
      ),
      const Duration(seconds: 30),
    );
    expect(
      estimateLocalArchiveRemaining(
        elapsed: const Duration(seconds: 1),
        progress: 0.25,
      ),
      isNull,
    );
    expect(formatLocalArchiveRemaining(const Duration(seconds: 65)), '1:05');
    expect(
      formatLocalArchiveRemaining(const Duration(seconds: 3665)),
      '1:01:05',
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
