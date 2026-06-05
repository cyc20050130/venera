import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/local.dart';
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
}
