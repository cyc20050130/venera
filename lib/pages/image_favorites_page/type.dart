enum ImageFavoriteSortType {
  title("Title"),
  timeAsc("Time Asc"),
  timeDesc("Time Desc"),
  maxFavorites("Favorite Num"), // 单本收藏数最多排序
  favoritesCompareComicPages("Favorite Num Compare Comic Pages"); // 单本收藏数比上总页数

  final String value;

  const ImageFavoriteSortType(this.value);
}

const numFilterList = [0, 1, 2, 5, 10, 20, 50, 100];

class TimeRange {
  /// End of the range, null means now
  final DateTime? end;

  /// Duration of the range
  final Duration duration;

  /// Create a time range
  const TimeRange({this.end, required this.duration});

  static const all = TimeRange(end: null, duration: Duration.zero);

  static const lastWeek = TimeRange(end: null, duration: Duration(days: 7));

  static const lastMonth = TimeRange(end: null, duration: Duration(days: 30));

  static const lastHalfYear = TimeRange(
    end: null,
    duration: Duration(days: 180),
  );

  static const lastYear = TimeRange(end: null, duration: Duration(days: 365));

  @override
  String toString() {
    return "${end?.millisecondsSinceEpoch}:${duration.inMilliseconds}";
  }

  /// Parse a time range from a string, return [TimeRange.all] if failed
  factory TimeRange.fromString(Object? value) {
    if (value is! String) {
      return TimeRange.all;
    }
    final parts = value.split(":");
    if (parts.length != 2) {
      return TimeRange.all;
    }
    final durationMs = int.tryParse(parts[1]);
    if (durationMs == null || durationMs < 0) {
      return TimeRange.all;
    }
    final endMs = parts[0] == "null" ? null : int.tryParse(parts[0]);
    if (parts[0] != "null" && endMs == null) {
      return TimeRange.all;
    }
    final end = endMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(endMs);
    final duration = Duration(milliseconds: durationMs);
    return TimeRange(end: end, duration: duration);
  }

  /// Check if a time is in the range
  bool contains(DateTime time) {
    if (end != null && time.isAfter(end!)) {
      return false;
    }
    if (duration == Duration.zero) {
      return true;
    }
    final start = end == null
        ? DateTime.now().subtract(duration)
        : end!.subtract(duration);
    return time.isAfter(start);
  }

  @override
  bool operator ==(Object other) {
    return other is TimeRange && other.end == end && other.duration == duration;
  }

  @override
  int get hashCode => end.hashCode ^ duration.hashCode;

  static const List<TimeRange> values = [
    all,
    lastWeek,
    lastMonth,
    lastHalfYear,
    lastYear,
  ];
}

int normalizeImageFavoriteNumberFilter(Object? value) {
  final parsed = switch (value) {
    int() => value,
    num() when value.isFinite && value == value.truncateToDouble() =>
      value.toInt(),
    String() => int.tryParse(value),
    _ => null,
  };
  if (parsed != null && numFilterList.contains(parsed)) {
    return parsed;
  }
  return numFilterList[0];
}

enum TimeRangeType {
  all("All"),
  lastWeek("Last Week"),
  lastMonth("Last Month"),
  lastHalfYear("Last Half Year"),
  lastYear("Last Year"),
  custom("Custom");

  final String value;

  const TimeRangeType(this.value);
}

TimeRange? resolveImageFavoriteTimeRangeSelection({
  required TimeRangeType type,
  DateTime? start,
  DateTime? end,
}) {
  return switch (type) {
    TimeRangeType.all => TimeRange.all,
    TimeRangeType.lastWeek => TimeRange.lastWeek,
    TimeRangeType.lastMonth => TimeRange.lastMonth,
    TimeRangeType.lastHalfYear => TimeRange.lastHalfYear,
    TimeRangeType.lastYear => TimeRange.lastYear,
    TimeRangeType.custom => _resolveCustomTimeRange(start: start, end: end),
  };
}

TimeRange? _resolveCustomTimeRange({DateTime? start, DateTime? end}) {
  if (start == null || end == null || end.isBefore(start)) {
    return null;
  }
  return TimeRange(end: end, duration: end.difference(start));
}
