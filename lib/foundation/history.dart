import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_details_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'consts.dart';

part "image_favorites.dart";

typedef HistoryType = ComicType;

@visibleForTesting
int decodeHistoryInt(dynamic value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

@visibleForTesting
int? decodeHistoryNullableInt(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

@visibleForTesting
String decodeHistoryString(dynamic value) {
  if (value == null) {
    return '';
  }
  return value.toString();
}

@visibleForTesting
bool? decodeHistoryBool(dynamic value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
    }
  }
  return null;
}

@visibleForTesting
DateTime decodeHistoryTime(dynamic value) {
  return DateTime.fromMillisecondsSinceEpoch(decodeHistoryInt(value));
}

@visibleForTesting
Set<String> decodeHistoryReadEpisode(dynamic value) {
  if (value == null) {
    return <String>{};
  }
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) {
      return <String>{};
    }
    if (text.startsWith('[')) {
      try {
        return decodeHistoryReadEpisode(jsonDecode(text));
      } catch (_) {
        return <String>{};
      }
    }
    return text
        .split(',')
        .map((element) => element.trim())
        .where((element) => element.isNotEmpty)
        .toSet();
  }
  if (value is Iterable) {
    return value
        .where((element) => element != null)
        .map((element) => element.toString())
        .where((element) => element.isNotEmpty)
        .toSet();
  }
  return {value.toString()};
}

@visibleForTesting
String decodeHistorySourceKey(dynamic sourceKey, dynamic typeValue) {
  final explicit = sourceKey?.toString();
  if (explicit != null && explicit.isNotEmpty) {
    return explicit;
  }
  return sourceKeyFromType(ComicType(decodeHistoryInt(typeValue)));
}

String sourceKeyFromType(ComicType type) {
  if (type == ComicType.local) {
    return "local";
  }
  return type.comicSource?.key ?? "Unknown:${type.value}";
}

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;

  String get sourceKey;
}

class History implements Comic {
  HistoryType type;

  final String stableSourceKey;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
  }) : type = model.historyType,
       stableSourceKey = model.sourceKey,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(decodeHistoryInt(map["type"])),
      stableSourceKey = decodeHistorySourceKey(map["sourceKey"], map["type"]),
      time = decodeHistoryTime(map["time"]),
      title = decodeHistoryString(map["title"]),
      subtitle = decodeHistoryString(map["subtitle"]),
      cover = decodeHistoryString(map["cover"]),
      ep = decodeHistoryInt(map["ep"]),
      page = decodeHistoryInt(map["page"]),
      id = decodeHistoryString(map["id"]),
      readEpisode = decodeHistoryReadEpisode(map["readEpisode"]),
      maxPage = decodeHistoryNullableInt(map["max_page"]),
      group = decodeHistoryNullableInt(map["group"] ?? map["chapter_group"]);

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  History.fromRow(Row row)
    : type = HistoryType(decodeHistoryInt(row["type"])),
      stableSourceKey = decodeHistorySourceKey(row["source_key"], row["type"]),
      time = decodeHistoryTime(row["time"]),
      title = decodeHistoryString(row["title"]),
      subtitle = decodeHistoryString(row["subtitle"]),
      cover = decodeHistoryString(row["cover"]),
      ep = decodeHistoryInt(row["ep"]),
      page = decodeHistoryInt(row["page"]),
      id = decodeHistoryString(row["id"]),
      readEpisode = decodeHistoryReadEpisode(row["readEpisode"]),
      maxPage = decodeHistoryNullableInt(row["max_page"]),
      group = decodeHistoryNullableInt(row["chapter_group"]);

  @override
  bool operator ==(Object other) {
    return other is History &&
        stableSourceKey == other.stableSourceKey &&
        id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, stableSourceKey);

  @override
  String get description {
    var res = "";
    if (group != null) {
      res += "${"Group @group".tlParams({"group": group!})} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": ep});
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": page});
    }
    return res;
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => stableSourceKey;

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;

  String get _dbPath => "${App.dataPath}/history.db";

  String _cacheKey(String id, String sourceKey) => "$id@$sourceKey";

  String _cacheKeyForHistory(History history) =>
      _cacheKey(history.id, history.sourceKey);

  int get length => count();

  /// Cache of history ids. Improve the performance of find operation.
  Map<String, bool>? _cachedHistoryIds;

  /// Cache records recently modified by the app. Improve the performance of listeners.
  final cachedHistories = <String, History>{};

  bool isInitialized = false;

  static const _createHistoryTableSql = """
        create table history (
          id text not null,
          source_key text not null,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int,
          primary key (id, source_key)
        );
      """;

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
    _db = sqlite3.open(_dbPath);

    _createHistoryTableIfNeeded();

    _upgradeHistorySchemaIfNeeded();

    notifyListeners();
    ImageFavoriteManager().init();
    isInitialized = true;
  }

  void _createHistoryTableIfNeeded() {
    _db.execute(
      _createHistoryTableSql.replaceFirst(
        "create table history",
        "create table if not exists history",
      ),
    );
  }

  bool _tableExists(String tableName) {
    final rows = _db.select(
      '''
        SELECT 1
        FROM sqlite_master
        WHERE type = 'table' AND name = ?
        LIMIT 1;
      ''',
      [tableName],
    );
    return rows.isNotEmpty;
  }

  void _upgradeHistorySchemaIfNeeded() {
    final hasLegacyTable = _tableExists("history_legacy");
    final columns = _db.select("PRAGMA table_info(history);");
    final hasSourceKey = columns.any(
      (element) => element["name"] == "source_key",
    );
    final hasChapterGroup = columns.any(
      (element) => element["name"] == "chapter_group",
    );

    if (!hasLegacyTable && hasSourceKey && hasChapterGroup) {
      return;
    }

    _db.execute("BEGIN TRANSACTION;");
    try {
      if (!hasLegacyTable) {
        _db.execute("ALTER TABLE history RENAME TO history_legacy;");
      }
      _createHistoryTableIfNeeded();

      final legacyColumns = _db.select("PRAGMA table_info(history_legacy);");
      final legacyHasChapterGroup = legacyColumns.any(
        (element) => element["name"] == "chapter_group",
      );

      final legacyRows = _db.select("SELECT * FROM history_legacy;");
      for (final row in legacyRows) {
        final typeValue = decodeHistoryInt(row["type"]);
        final sourceKey = sourceKeyFromType(ComicType(typeValue));
        _db.execute(_insertHistorySql, [
          row["id"],
          sourceKey,
          row["title"],
          row["subtitle"],
          row["cover"],
          row["time"],
          typeValue,
          row["ep"],
          row["page"],
          row["readEpisode"],
          row["max_page"],
          legacyHasChapterGroup ? row["chapter_group"] : null,
        ]);
      }

      _db.execute("DROP TABLE history_legacy;");
      _db.execute("COMMIT;");
    } catch (e) {
      _db.execute("ROLLBACK;");
      rethrow;
    }
  }

  static const _insertHistorySql = """
        insert or replace into history (id, source_key, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  static Future<void> _addHistoryAsync(String dbPath, History newItem) {
    return Isolate.run(() {
      final db = sqlite3.open(dbPath);
      try {
        db.execute(_insertHistorySql, [
          newItem.id,
          newItem.sourceKey,
          newItem.title,
          newItem.subtitle,
          newItem.cover,
          newItem.time.millisecondsSinceEpoch,
          newItem.type.value,
          newItem.ep,
          newItem.page,
          newItem.readEpisode.join(','),
          newItem.maxPage,
          newItem.group,
        ]);
      } finally {
        db.dispose();
      }
    });
  }

  bool _haveAsyncTask = false;

  /// Create a isolate to add history to prevent blocking the UI thread.
  Future<void> addHistoryAsync(History newItem, {bool notify = true}) async {
    if (!isInitialized) {
      throw StateError('HistoryManager is not initialized');
    }
    while (_haveAsyncTask) {
      await Future.delayed(Duration(milliseconds: 20));
    }

    _haveAsyncTask = true;
    try {
      await _addHistoryAsync(_dbPath, newItem);
    } finally {
      _haveAsyncTask = false;
    }
    if (_cachedHistoryIds == null) {
      updateCache();
    } else {
      _cachedHistoryIds![_cacheKeyForHistory(newItem)] = true;
    }
    cachedHistories[_cacheKeyForHistory(newItem)] = newItem;
    if (cachedHistories.length > 10) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
    if (notify) {
      notifyListeners();
    }
  }

  /// add history. if exists, update time.
  ///
  /// This function would be called when user start reading.
  void addHistory(History newItem, {bool notify = true}) {
    _db.execute(_insertHistorySql, [
      newItem.id,
      newItem.sourceKey,
      newItem.title,
      newItem.subtitle,
      newItem.cover,
      newItem.time.millisecondsSinceEpoch,
      newItem.type.value,
      newItem.ep,
      newItem.page,
      newItem.readEpisode.join(','),
      newItem.maxPage,
      newItem.group,
    ]);
    if (_cachedHistoryIds == null) {
      updateCache();
    } else {
      _cachedHistoryIds![_cacheKeyForHistory(newItem)] = true;
    }
    cachedHistories[_cacheKeyForHistory(newItem)] = newItem;
    if (cachedHistories.length > 10) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
    if (notify) {
      notifyListeners();
    }
  }

  void clearHistory() {
    _db.execute("delete from history;");
    updateCache();
    notifyListeners();
  }

  void clearUnfavoritedHistory() {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final idAndTypes = _db.select("""
      select id, source_key, type from history;
    """);
      for (var element in idAndTypes) {
        final id = decodeHistoryString(element["id"]);
        final sourceKey = decodeHistoryString(element["source_key"]);
        if (id.isEmpty || sourceKey.isEmpty) {
          continue;
        }
        final type = ComicType(decodeHistoryInt(element["type"]));
        if (!LocalFavoritesManager().isExist(id, type)) {
          _db.execute(
            """
          delete from history
          where id == ? and source_key == ?;
        """,
            [id, sourceKey],
          );
        }
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  void remove(String id, ComicType type) async {
    removeBySourceKey(id, sourceKeyFromType(type));
  }

  void removeBySourceKey(String id, String sourceKey) {
    _db.execute(
      """
      delete from history
      where id == ? and source_key == ?;
    """,
      [id, sourceKey],
    );
    updateCache();
    notifyListeners();
  }

  void updateCache() {
    _cachedHistoryIds = {};
    var res = _db.select("""
        select id, source_key from history;
      """);
    for (var element in res) {
      final id = decodeHistoryString(element["id"]);
      final sourceKey = decodeHistoryString(element["source_key"]);
      if (id.isEmpty || sourceKey.isEmpty) {
        continue;
      }
      _cachedHistoryIds![_cacheKey(id, sourceKey)] = true;
    }
    for (var key in cachedHistories.keys.toList()) {
      if (!_cachedHistoryIds!.containsKey(key)) {
        cachedHistories.remove(key);
      }
    }
  }

  History? find(String id, ComicType type) {
    return findBySourceKey(id, sourceKeyFromType(type));
  }

  History? findBySourceKey(String id, String sourceKey) {
    final key = _cacheKey(id, sourceKey);
    if (_cachedHistoryIds == null) {
      updateCache();
    }
    if (!_cachedHistoryIds!.containsKey(key)) {
      return null;
    }
    if (cachedHistories.containsKey(key)) {
      return cachedHistories[key];
    }

    var res = _db.select(
      """
      select * from history
      where id == ? and source_key == ?;
    """,
      [id, sourceKey],
    );
    if (res.isEmpty) {
      return null;
    }
    return History.fromRow(res.first);
  }

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      order by time DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = _db.select("""
      select count(*) from history;
    """);
    return decodeHistoryInt(res.first[0]);
  }

  void flush() {
    if (!isInitialized) {
      return;
    }
    _db.execute("PRAGMA wal_checkpoint(FULL);");
  }

  void close() {
    if (isInitialized) {
      _db.dispose();
    }
    isInitialized = false;
    _cachedHistoryIds = null;
    cachedHistories.clear();
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute(
          """
          delete from history
          where id == ? and source_key == ?;
        """,
          [history.id, sourceKeyFromType(history.type)],
        );
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(History history) async {
    if (history.sourceKey == 'local') {
      // Local comics don't need refresh
      return false;
    }

    return await _refreshSingleHistory(history);
  }

  /// Internal method to refresh a single history
  /// Retries up to 3 times on failure with 2 second delay between retries
  Future<bool> _refreshSingleHistory(History history) async {
    var comicSource = ComicSource.find(history.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return false;
    }

    int retries = 3;
    while (true) {
      try {
        var res = await ComicDetailsRepository().load(
          history.sourceKey,
          history.id,
          forceRefresh: true,
          refreshIfStale: false,
        );
        if (res.error) {
          await Future.delayed(const Duration(seconds: 2));
          retries--;
          if (retries == 0) {
            return false;
          }
          continue;
        }

        var comicDetails = res.data;
        // Update history info while keeping reading progress
        var updatedHistory = History.fromMap({
          'type': history.type.value,
          'sourceKey': history.sourceKey,
          'time': history.time.millisecondsSinceEpoch,
          'title': comicDetails.title,
          'subtitle': comicDetails.subTitle ?? '',
          'cover': comicDetails.cover,
          'ep': history.ep,
          'page': history.page,
          'id': history.id,
          'readEpisode': history.readEpisode.toList(),
          'max_page': history.maxPage,
        });
        updatedHistory.group = history.group;

        addHistory(updatedHistory);
        return true;
      } catch (e, s) {
        Log.error("History", "Exception while refreshing history info: $e\n$s");
        await Future.delayed(const Duration(seconds: 2));
        retries--;
        if (retries == 0) {
          return false;
        }
      }
    }
  }

  /// Refresh all histories from comic sources.
  /// Returns a stream with progress updates.
  /// From e0ea449c.
  Stream<RefreshProgress> refreshAllHistoriesStream() {
    var controller = StreamController<RefreshProgress>();
    _refreshAllHistoriesBase(controller);
    return controller.stream;
  }

  void _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
  ) async {
    var histories = getAll();
    int total = histories.length;
    int current = 0;
    int success = 0;
    int failed = 0;
    int skipped = 0;

    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var historiesToRefresh = <History>[];
    for (var history in histories) {
      if (history.sourceKey == 'local') {
        skipped++;
        current++;
        controller.add(
          RefreshProgress(total, current, success, failed, skipped),
        );
        continue;
      }
      historiesToRefresh.add(history);
    }

    total = historiesToRefresh.length;
    current = 0;
    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var channel = Channel<History>(10);

    () async {
      var c = 0;
      for (var history in historiesToRefresh) {
        await channel.push(history);
        c++;
        if (c % 5 == 0) {
          var delay = c % 100 + 1;
          if (delay > 10) {
            delay = 10;
          }
          await Future.delayed(Duration(seconds: delay));
        }
      }
      channel.close();
    }();

    var updateFutures = <Future>[];
    for (var i = 0; i < 5; i++) {
      var f = () async {
        while (true) {
          var history = await channel.pop();
          if (history == null) {
            break;
          }
          var result = await _refreshSingleHistory(history);
          current++;
          if (result) {
            success++;
          } else {
            failed++;
          }
          controller.add(
            RefreshProgress(total, current, success, failed, skipped),
          );
        }
      }();
      updateFutures.add(f);
    }

    await Future.wait(updateFutures);

    notifyListeners();
    controller.close();
  }
}

class RefreshProgress {
  final int total;
  final int current;
  final int success;
  final int failed;
  final int skipped;

  RefreshProgress(
    this.total,
    this.current,
    this.success,
    this.failed,
    this.skipped,
  );
}
