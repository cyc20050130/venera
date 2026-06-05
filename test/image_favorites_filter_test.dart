import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/image_favorites_page/type.dart';

void main() {
  test('TimeRange serializes null end ranges without losing duration', () {
    final parsed = TimeRange.fromString(TimeRange.lastWeek.toString());

    expect(parsed.end, isNull);
    expect(parsed.duration, TimeRange.lastWeek.duration);
  });

  test('TimeRange serializes explicit end timestamps', () {
    final end = DateTime.fromMillisecondsSinceEpoch(1710000123456);
    final range = TimeRange(end: end, duration: const Duration(hours: 3));
    final parsed = TimeRange.fromString(range.toString());

    expect(parsed.end, end);
    expect(parsed.duration, range.duration);
  });

  test('TimeRange rejects malformed values', () {
    expect(TimeRange.fromString(null), TimeRange.all);
    expect(TimeRange.fromString(123), TimeRange.all);
    expect(TimeRange.fromString(['bad']), TimeRange.all);
    expect(TimeRange.fromString('bad'), TimeRange.all);
    expect(TimeRange.fromString('null:bad'), TimeRange.all);
    expect(TimeRange.fromString('bad:100'), TimeRange.all);
    expect(TimeRange.fromString('null:-1'), TimeRange.all);
  });

  test('normalizeImageFavoriteNumberFilter accepts only known filters', () {
    expect(normalizeImageFavoriteNumberFilter(null), 0);
    expect(normalizeImageFavoriteNumberFilter(2), 2);
    expect(normalizeImageFavoriteNumberFilter(2.0), 2);
    expect(normalizeImageFavoriteNumberFilter(2.9), 0);
    expect(normalizeImageFavoriteNumberFilter('10'), 10);
    expect(normalizeImageFavoriteNumberFilter('bad'), 0);
    expect(normalizeImageFavoriteNumberFilter(999), 0);
    expect(normalizeImageFavoriteNumberFilter(['bad']), 0);
  });

  test('image favorite time range selection resolves preset filters', () {
    expect(
      resolveImageFavoriteTimeRangeSelection(type: TimeRangeType.all),
      TimeRange.all,
    );
    expect(
      resolveImageFavoriteTimeRangeSelection(type: TimeRangeType.lastMonth),
      TimeRange.lastMonth,
    );
  });

  test('image favorite custom time range requires a valid start and end', () {
    final start = DateTime(2026, 6, 1);
    final end = DateTime(2026, 6, 5);

    expect(
      resolveImageFavoriteTimeRangeSelection(
        type: TimeRangeType.custom,
        start: start,
        end: end,
      ),
      TimeRange(end: end, duration: end.difference(start)),
    );
    expect(
      resolveImageFavoriteTimeRangeSelection(
        type: TimeRangeType.custom,
        start: null,
        end: end,
      ),
      isNull,
    );
    expect(
      resolveImageFavoriteTimeRangeSelection(
        type: TimeRangeType.custom,
        start: start,
        end: null,
      ),
      isNull,
    );
    expect(
      resolveImageFavoriteTimeRangeSelection(
        type: TimeRangeType.custom,
        start: end,
        end: start,
      ),
      isNull,
    );
  });
}
