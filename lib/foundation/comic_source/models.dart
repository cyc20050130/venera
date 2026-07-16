part of 'comic_source.dart';

String comicSourceString(dynamic value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

@visibleForTesting
String? comicSourceNullableString(dynamic value) {
  if (value == null) {
    return null;
  }
  return value.toString();
}

@visibleForTesting
int? comicSourceInt(dynamic value) {
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
double? comicSourceDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

bool? comicSourceBool(dynamic value) {
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
List<String> comicSourceStringList(dynamic value) {
  if (value is! Iterable) {
    return <String>[];
  }
  return value
      .where((element) => element != null)
      .map((element) => element.toString())
      .toList();
}

@visibleForTesting
List<String>? comicSourceStringListOrNull(dynamic value) {
  if (value == null) {
    return null;
  }
  return comicSourceStringList(value);
}

Map<String, dynamic>? comicSourceMapOrNull(dynamic value) {
  if (value is! Map) {
    return null;
  }
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key == null) {
      continue;
    }
    result[key.toString()] = entry.value;
  }
  return result;
}

List<Map<String, dynamic>> comicSourceMapList(dynamic value) {
  if (value is! Iterable) {
    return <Map<String, dynamic>>[];
  }
  return value
      .map(comicSourceMapOrNull)
      .whereType<Map<String, dynamic>>()
      .toList();
}

@visibleForTesting
Map<String, List<String>> comicSourceTagsMap(dynamic value) {
  final map = comicSourceMapOrNull(value);
  if (map == null) {
    return <String, List<String>>{};
  }
  final result = <String, List<String>>{};
  for (final entry in map.entries) {
    final value = entry.value;
    if (value == null) {
      continue;
    }
    if (value is Iterable) {
      result[entry.key] = comicSourceStringList(value);
    } else {
      result[entry.key] = [value.toString()];
    }
  }
  return result;
}

@visibleForTesting
Map<String, Map<String, dynamic>> normalizeSourceSettings(dynamic value) {
  if (value is! Map) {
    return <String, Map<String, dynamic>>{};
  }
  final result = <String, Map<String, dynamic>>{};
  for (final entry in value.entries) {
    final key = entry.key;
    final item = entry.value;
    if (key is! String || item is! Map) {
      continue;
    }
    final normalized = <String, dynamic>{};
    for (final itemEntry in item.entries) {
      final itemKey = itemEntry.key;
      if (itemKey is! String) {
        continue;
      }
      var itemValue = itemEntry.value;
      if (itemValue is JSInvokable) {
        itemValue = JSAutoFreeFunction(itemValue);
      }
      normalized[itemKey] = itemValue;
    }
    result[key] = normalized;
  }
  return result;
}

class Comment {
  static const int _maxDateTimeMillisecondsSinceEpoch = 8640000000000000;

  final String userName;
  final String? avatar;
  final String content;
  final String? time;
  final int? replyCount;
  final String? id;
  int? score;
  final bool? isLiked;
  int? voteStatus; // 1: upvote, -1: downvote, 0: none

  static String? parseTime(dynamic value) {
    if (value == null) return null;
    if (value is int) {
      final milliseconds = value.abs() < 10000000000 ? value * 1000 : value;
      if (milliseconds.abs() > _maxDateTimeMillisecondsSinceEpoch) {
        return value.toString();
      }
      try {
        return DateTime.fromMillisecondsSinceEpoch(
          milliseconds,
        ).toString().substring(0, 19);
      } catch (_) {
        return value.toString();
      }
    }
    return value.toString();
  }

  Comment.fromJson(Map<String, dynamic> json)
    : userName = comicSourceString(json["userName"]),
      avatar = comicSourceNullableString(json["avatar"]),
      content = comicSourceString(json["content"]),
      time = parseTime(json["time"]),
      replyCount = comicSourceInt(json["replyCount"]),
      id = comicSourceNullableString(json["id"]),
      score = comicSourceInt(json["score"]),
      isLiked = comicSourceBool(json["isLiked"]),
      voteStatus = comicSourceInt(json["voteStatus"]);

  Map<String, dynamic> toJson() {
    return {
      "userName": userName,
      "avatar": avatar,
      "content": content,
      "time": time,
      "replyCount": replyCount,
      "id": id,
      "score": score,
      "isLiked": isLiked,
      "voteStatus": voteStatus,
    };
  }
}

class Comic {
  final String title;

  final String cover;

  final String id;

  final String? subtitle;

  final List<String>? tags;

  final String description;

  final String sourceKey;

  final int? maxPage;

  final String? language;

  final String? favoriteId;

  /// 0-5
  final double? stars;

  const Comic(
    this.title,
    this.cover,
    this.id,
    this.subtitle,
    this.tags,
    this.description,
    this.sourceKey,
    this.maxPage,
    this.language,
  ) : favoriteId = null,
      stars = null;

  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "maxPage": maxPage,
      "language": language,
      "favoriteId": favoriteId,
    };
  }

  Comic.fromJson(Map<String, dynamic> json, this.sourceKey)
    : title = comicSourceString(json["title"]),
      subtitle =
          comicSourceNullableString(json["subtitle"] ?? json["subTitle"]) ?? "",
      cover = comicSourceString(json["cover"]),
      id = comicSourceString(json["id"]),
      tags = comicSourceStringList(json["tags"]),
      description = comicSourceString(json["description"]),
      maxPage = comicSourceInt(json["maxPage"]),
      language = comicSourceNullableString(json["language"]),
      favoriteId = comicSourceNullableString(json["favoriteId"]),
      stars = comicSourceDouble(json["stars"]);

  @override
  bool operator ==(Object other) {
    if (other is! Comic) return false;
    return other.id == id && other.sourceKey == sourceKey;
  }

  @override
  int get hashCode => id.hashCode ^ sourceKey.hashCode;

  @override
  toString() => "$sourceKey@$id";
}

/// Stable identity without adding a new required member to the legacy
/// [Comic] interface. Several persisted models use `implements Comic`; an
/// extension keeps those models source-compatible during the migration.
extension ComicKeyExtension on Comic {
  ComicKey get comicKey => ComicKey(sourceKey: sourceKey, comicId: id);
}

class ComicID {
  final ComicType type;

  final String id;

  const ComicID(this.type, this.id);

  @override
  bool operator ==(Object other) {
    if (other is! ComicID) return false;
    return other.type == type && other.id == id;
  }

  @override
  int get hashCode => type.hashCode ^ id.hashCode;

  @override
  String toString() => "$type@$id";
}

class ComicDetails with HistoryMixin {
  @override
  final String title;

  @override
  final String? subTitle;

  @override
  final String cover;

  final String? description;

  final Map<String, List<String>> tags;

  /// id-name
  final ComicChapters? chapters;

  final List<String>? thumbnails;

  final List<Comic>? recommend;

  @override
  final String sourceKey;

  final String comicId;

  final bool? isFavorite;

  final String? subId;

  final bool? isLiked;

  final int? likesCount;

  final int? commentCount;

  final String? uploader;

  final String? uploadTime;

  final String? updateTime;

  final String? url;

  final double? stars;

  @override
  final int? maxPage;

  final List<Comment>? comments;

  ComicDetails.fromJson(Map<String, dynamic> json)
    : title = comicSourceString(json["title"]),
      subTitle = comicSourceNullableString(
        json["subtitle"] ?? json["subTitle"],
      ),
      cover = comicSourceString(json["cover"]),
      description = comicSourceNullableString(json["description"]),
      tags = comicSourceTagsMap(json["tags"]),
      chapters = ComicChapters.fromJsonOrNull(json["chapters"]),
      sourceKey = comicSourceString(json["sourceKey"]),
      comicId = comicSourceString(json["comicId"]),
      thumbnails = comicSourceStringListOrNull(json["thumbnails"]),
      recommend = json["recommend"] == null
          ? null
          : comicSourceMapList(json["recommend"])
                .map(
                  (e) =>
                      Comic.fromJson(e, comicSourceString(json["sourceKey"])),
                )
                .toList(),
      isFavorite = comicSourceBool(json["isFavorite"]),
      subId = comicSourceNullableString(json["subId"]),
      likesCount = comicSourceInt(json["likesCount"]),
      isLiked = comicSourceBool(json["isLiked"]),
      commentCount = comicSourceInt(json["commentCount"]),
      uploader = comicSourceNullableString(json["uploader"]),
      uploadTime = comicSourceNullableString(json["uploadTime"]),
      updateTime = comicSourceNullableString(json["updateTime"]),
      url = comicSourceNullableString(json["url"]),
      stars = comicSourceDouble(json["stars"]),
      maxPage = comicSourceInt(json["maxPage"]),
      comments = json["comments"] == null
          ? null
          : comicSourceMapList(
              json["comments"],
            ).map((e) => Comment.fromJson(e)).toList();

  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "subTitle": subTitle,
      "cover": cover,
      "description": description,
      "tags": tags,
      "chapters": chapters,
      "thumbnails": thumbnails,
      "recommend": recommend?.map((e) => e.toJson()).toList(),
      "sourceKey": sourceKey,
      "comicId": comicId,
      "isFavorite": isFavorite,
      "subId": subId,
      "isLiked": isLiked,
      "likesCount": likesCount,
      "commentCount": commentCount,
      "uploader": uploader,
      "uploadTime": uploadTime,
      "updateTime": updateTime,
      "url": url,
      "stars": stars,
      "maxPage": maxPage,
      "comments": comments?.map((e) => e.toJson()).toList(),
    };
  }

  @override
  HistoryType get historyType => HistoryType(sourceKey.hashCode);

  @override
  String get id => comicId;

  ComicType get comicType => ComicType(sourceKey.hashCode);

  /// Convert tags map to plain list
  List<String> get plainTags {
    var res = <String>[];
    tags.forEach((key, value) {
      res.addAll(value.map((e) => "$key:$e"));
    });
    return res;
  }

  /// Find the first author tag
  String? findAuthor() {
    var authorNamespaces = [
      "author",
      "authors",
      "artist",
      "artists",
      "作者",
      "画师",
    ];
    for (var entry in tags.entries) {
      if (authorNamespaces.contains(entry.key.toLowerCase()) &&
          entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }

  String? _validateUpdateTime(String time) {
    time = time.split(" ").first;
    var segments = time.split("-");
    if (segments.length != 3) return null;
    var year = int.tryParse(segments[0]);
    var month = int.tryParse(segments[1]);
    var day = int.tryParse(segments[2]);
    if (year == null || month == null || day == null) return null;
    if (year < 2000 || year > 3000) return null;
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    return "$year-$month-$day";
  }

  String? findUpdateTime() {
    if (updateTime != null) {
      return _validateUpdateTime(updateTime!);
    }
    const acceptedNamespaces = ["更新", "最後更新", "最后更新", "update", "last update"];
    for (var entry in tags.entries) {
      if (acceptedNamespaces.contains(entry.key.toLowerCase()) &&
          entry.value.isNotEmpty) {
        var value = entry.value.first;
        return _validateUpdateTime(value);
      }
    }
    return null;
  }
}

class ArchiveInfo {
  final String title;
  final String description;
  final String id;

  ArchiveInfo.fromJson(Map<String, dynamic> json)
    : title = comicSourceString(json["title"]),
      description = comicSourceString(json["description"]),
      id = comicSourceString(json["id"]);
}

class ComicChapters {
  final Map<String, String>? _chapters;

  final Map<String, Map<String, String>>? _groupedChapters;

  /// Create a ComicChapters object with a flat map
  const ComicChapters(Map<String, String> this._chapters)
    : _groupedChapters = null;

  /// Create a ComicChapters object with a grouped map
  const ComicChapters.grouped(
    Map<String, Map<String, String>> this._groupedChapters,
  ) : _chapters = null;

  factory ComicChapters.fromJson(dynamic json) {
    if (json is! Map) throw ArgumentError("Invalid json type");
    var chapters = <String, String>{};
    var groupedChapters = <String, Map<String, String>>{};
    for (var entry in json.entries) {
      var key = entry.key?.toString();
      var value = entry.value;
      if (key == null) {
        continue;
      }
      if (value is Map) {
        final group = <String, String>{};
        for (final groupEntry in value.entries) {
          final groupKey = groupEntry.key?.toString();
          final groupValue = groupEntry.value;
          if (groupKey == null || groupValue == null) {
            continue;
          }
          group[groupKey] = groupValue.toString();
        }
        if (group.isNotEmpty) {
          groupedChapters[key] = group;
        }
      } else if (value != null) {
        chapters[key] = value.toString();
      }
    }
    if (chapters.isNotEmpty) {
      return ComicChapters(chapters);
    } else if (groupedChapters.isNotEmpty) {
      return ComicChapters.grouped(groupedChapters);
    } else {
      // return a empty list.
      return ComicChapters(chapters);
    }
  }

  static fromJsonOrNull(dynamic json) {
    if (json == null) return null;
    try {
      return ComicChapters.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() {
    if (_chapters != null) {
      return _chapters;
    } else {
      return _groupedChapters!;
    }
  }

  /// Whether the chapters are grouped
  bool get isGrouped => _groupedChapters != null;

  /// All group names
  Iterable<String> get groups => _groupedChapters?.keys ?? [];

  /// All chapters.
  /// If the chapters are grouped, all groups will be merged.
  Map<String, String> get allChapters {
    if (_chapters != null) return _chapters;
    var res = <String, String>{};
    for (var entry in _groupedChapters!.values) {
      res.addAll(entry);
    }
    return res;
  }

  /// Get a group of chapters by name
  Map<String, String> getGroup(String group) {
    return _groupedChapters![group] ?? {};
  }

  /// Get a group of chapters by index(0-based)
  Map<String, String> getGroupByIndex(int index) {
    if (_groupedChapters == null ||
        index < 0 ||
        index >= _groupedChapters.length) {
      return {};
    }
    return _groupedChapters.values.elementAt(index);
  }

  /// Get total number of chapters
  int get length {
    return isGrouped
        ? _groupedChapters!.values.fold(0, (sum, group) => sum + group.length)
        : _chapters!.length;
  }

  /// Get the number of groups
  int get groupCount => _groupedChapters?.length ?? 0;

  /// Iterate all chapter ids
  Iterable<String> get ids sync* {
    if (isGrouped) {
      for (var entry in _groupedChapters!.values) {
        yield* entry.keys;
      }
    } else {
      yield* _chapters!.keys;
    }
  }

  /// Iterate all chapter titles
  Iterable<String> get titles sync* {
    if (isGrouped) {
      for (var entry in _groupedChapters!.values) {
        yield* entry.values;
      }
    } else {
      yield* _chapters!.values;
    }
  }

  String? operator [](String key) {
    if (isGrouped) {
      for (var entry in _groupedChapters!.values) {
        if (entry.containsKey(key)) return entry[key];
      }
      return null;
    } else {
      return _chapters![key];
    }
  }
}

class PageJumpTarget {
  final String sourceKey;

  final String page;

  final Map<String, dynamic>? attributes;

  const PageJumpTarget(this.sourceKey, this.page, this.attributes);

  static PageJumpTarget parse(String sourceKey, dynamic value) {
    final mapValue = comicSourceMapOrNull(value);
    if (mapValue != null) {
      if (mapValue['page'] != null) {
        return PageJumpTarget(
          sourceKey,
          comicSourceString(mapValue["page"], fallback: "search"),
          comicSourceMapOrNull(mapValue["attributes"]),
        );
      } else if (mapValue["action"] != null) {
        // old version `onClickTag`
        var page = comicSourceString(mapValue["action"]);
        if (page == "search") {
          return PageJumpTarget(sourceKey, "search", {
            "text": comicSourceString(mapValue["keyword"]),
          });
        } else if (page == "category") {
          return PageJumpTarget(sourceKey, "category", {
            "category": comicSourceString(mapValue["keyword"]),
            "param": comicSourceNullableString(mapValue["param"]),
          });
        } else {
          return PageJumpTarget(sourceKey, page, null);
        }
      }
    } else if (value is String) {
      // old version string encoding. search: `search:keyword`, category: `category:keyword` or `category:keyword@param`
      final separator = value.indexOf(":");
      final page = separator == -1 ? value : value.substring(0, separator);
      final payload = separator == -1 ? "" : value.substring(separator + 1);
      if (page == "search") {
        return PageJumpTarget(sourceKey, "search", {"text": payload});
      } else if (page == "category") {
        var c = payload;
        final paramSeparator = c.indexOf('@');
        if (paramSeparator != -1) {
          return PageJumpTarget(sourceKey, "category", {
            "category": c.substring(0, paramSeparator),
            "param": c.substring(paramSeparator + 1),
          });
        } else {
          return PageJumpTarget(sourceKey, "category", {"category": c});
        }
      } else {
        return PageJumpTarget(sourceKey, page, null);
      }
    }
    return PageJumpTarget(sourceKey, "Invalid Data", null);
  }

  void jump(BuildContext context) {
    if (page == "search") {
      context.to(
        () => SearchResultPage(
          text: attributes?["text"] ?? attributes?["keyword"] ?? "",
          sourceKey: sourceKey,
          options: comicSourceStringList(attributes?["options"]),
        ),
      );
    } else if (page == "category") {
      final source = ComicSource.find(sourceKey);
      final key = source?.categoryData?.key;
      final category = comicSourceNullableString(attributes?["category"]);
      if (key == null || category == null) {
        Log.error(
          "Page Jump",
          "Cannot jump to category for source=$sourceKey page=$page",
        );
        return;
      }
      context.to(
        () => CategoryComicsPage(
          categoryKey: key,
          category: category,
          options: comicSourceStringList(attributes?["options"]),
          param: comicSourceNullableString(attributes?["param"]),
        ),
      );
    } else {
      Log.error("Page Jump", "Unknown page: $page");
    }
  }
}
