part of 'comic_source.dart';

/// return true if ver1 > ver2
bool compareSemVer(String ver1, String ver2) {
  ver1 = ver1.replaceFirst("-", ".");
  ver2 = ver2.replaceFirst("-", ".");
  List<String> v1 = ver1.split('.');
  List<String> v2 = ver2.split('.');

  for (int i = 0; i < 3; i++) {
    int num1 = parseSemVerNumberPart(v1, i);
    int num2 = parseSemVerNumberPart(v2, i);

    if (num1 > num2) {
      return true;
    } else if (num1 < num2) {
      return false;
    }
  }

  var v14 = v1.elementAtOrNull(3);
  var v24 = v2.elementAtOrNull(3);

  if (v14 != v24) {
    if (v14 == null && v24 != "hotfix") {
      return true;
    } else if (v14 == null) {
      return false;
    }
    if (v24 == null) {
      if (v14 == "hotfix") {
        return true;
      }
      return false;
    }
    return v14.compareTo(v24) > 0;
  }

  return false;
}

@visibleForTesting
int parseSemVerNumberPart(List<String> parts, int index) {
  if (index < 0 || index >= parts.length) {
    return 0;
  }
  return int.tryParse(parts[index]) ?? 0;
}

@visibleForTesting
String? extractComicSourceClassName(String js) {
  for (final line in js.replaceAll("\r\n", "\n").split('\n')) {
    final match = RegExp(
      r'^class\s+([A-Za-z_$][\w$]*)\s+extends\s+ComicSource\b',
    ).firstMatch(line.trim());
    if (match != null) {
      return match.group(1);
    }
  }
  return null;
}

@visibleForTesting
List<Comic> normalizeSourceComicList(Object? value, String sourceKey) {
  if (value is! Iterable) {
    return <Comic>[];
  }
  final comics = <Comic>[];
  for (final item in value) {
    final map = comicSourceMapOrNull(item);
    if (map == null) {
      continue;
    }
    try {
      comics.add(Comic.fromJson(map, sourceKey));
    } catch (e, s) {
      Log.warning('Data Analysis', 'Skip invalid comic item: $e\n$s');
    }
  }
  return comics;
}

@visibleForTesting
Res<List<Comic>> normalizeSourceComicListResult(
  Object? value,
  String sourceKey, {
  String subDataKey = 'maxPage',
}) {
  final map = comicSourceMapOrNull(value);
  if (map == null) {
    return Res.error("Invalid data:\nExpected: Map\nGot: ${value.runtimeType}");
  }
  return Res(
    normalizeSourceComicList(map['comics'], sourceKey),
    subData: map[subDataKey],
  );
}

@visibleForTesting
ExplorePagePart? normalizeExplorePagePart(Object? value, String sourceKey) {
  final map = comicSourceMapOrNull(value);
  if (map == null) {
    return null;
  }
  return ExplorePagePart(
    comicSourceString(map['title']),
    normalizeSourceComicList(map['comics'], sourceKey),
    map.containsKey('viewMore')
        ? PageJumpTarget.parse(sourceKey, map['viewMore'])
        : null,
  );
}

@visibleForTesting
List<ExplorePagePart> normalizeExplorePageParts(
  Object? value,
  String sourceKey,
) {
  if (value is Map) {
    final parts = <ExplorePagePart>[];
    for (final entry in value.entries) {
      final comics = normalizeSourceComicList(entry.value, sourceKey);
      if (comics.isEmpty) {
        continue;
      }
      parts.add(ExplorePagePart(entry.key.toString(), comics, null));
    }
    return parts;
  }
  if (value is! Iterable) {
    return <ExplorePagePart>[];
  }
  return value
      .map((entry) => normalizeExplorePagePart(entry, sourceKey))
      .whereType<ExplorePagePart>()
      .toList();
}

@visibleForTesting
List<Object> normalizeMixedExploreData(Object? value, String sourceKey) {
  if (value is! Iterable) {
    return <Object>[];
  }
  final result = <Object>[];
  for (final item in value) {
    if (item is Iterable) {
      final comics = normalizeSourceComicList(item, sourceKey);
      if (comics.isNotEmpty) {
        result.add(comics);
      }
    } else {
      final part = normalizeExplorePagePart(item, sourceKey);
      if (part != null) {
        result.add(part);
      }
    }
  }
  return result;
}

@visibleForTesting
({String title, ExplorePageType type})? normalizeExplorePageDefinition(
  Object? title,
  Object? type,
) {
  final pageTitle = comicSourceNullableString(title);
  final typeName = comicSourceNullableString(type);
  if (pageTitle == null || pageTitle.isEmpty || typeName == null) {
    return null;
  }
  return switch (typeName) {
    "singlePageWithMultiPart" || "multiPartPage" => (
      title: pageTitle,
      type: ExplorePageType.singlePageWithMultiPart,
    ),
    "multiPageComicList" => (
      title: pageTitle,
      type: ExplorePageType.multiPageComicList,
    ),
    "mixed" => (title: pageTitle, type: ExplorePageType.mixed),
    _ => null,
  };
}

@visibleForTesting
bool isNewCategoryFormatList(List? categories) {
  return categories == null || categories.isEmpty || categories.first is Map;
}

@visibleForTesting
LinkedHashMap<String, String> parseCategoryOptionEntries(Object? value) {
  final map = LinkedHashMap<String, String>.of(const {});
  if (value is! Iterable) {
    return map;
  }
  for (final option in value) {
    if (option == null) {
      continue;
    }
    final optionText = option.toString();
    if (optionText.isEmpty || !optionText.contains("-")) {
      continue;
    }
    final split = optionText.split("-");
    final key = split.removeAt(0);
    final optionValue = split.join("-");
    if (key.isEmpty) {
      continue;
    }
    map[key] = optionValue;
  }
  return map;
}

@visibleForTesting
CategoryComicsOptions? normalizeCategoryComicsOptionsItem(Object? value) {
  final item = comicSourceMapOrNull(value);
  if (item == null) {
    return null;
  }
  final options = parseCategoryOptionEntries(item["options"]);
  if (options.isEmpty) {
    return null;
  }
  return CategoryComicsOptions(
    comicSourceString(item["label"]),
    options,
    comicSourceStringList(item["notShowWhen"]),
    item["showWhen"] == null ? null : comicSourceStringList(item["showWhen"]),
  );
}

@visibleForTesting
SearchOptions? normalizeSearchOptionsItem(Object? value) {
  final item = comicSourceMapOrNull(value);
  if (item == null) {
    return null;
  }
  final options = parseCategoryOptionEntries(item["options"]);
  if (options.isEmpty) {
    return null;
  }
  final type = comicSourceString(item["type"], fallback: "select");
  return SearchOptions(
    options,
    comicSourceString(item["label"]),
    switch (type) {
      "multi-select" || "dropdown" => type,
      _ => "select",
    },
    item["default"] == null ? null : jsonEncode(item["default"]),
  );
}

@visibleForTesting
ComicDetails? normalizeComicDetailsPayload(
  Object? value, {
  required String sourceKey,
  required String comicId,
}) {
  final data = comicSourceMapOrNull(value);
  if (data == null) {
    return null;
  }
  data['comicId'] = comicId;
  data['sourceKey'] = sourceKey;
  return ComicDetails.fromJson(data);
}

@visibleForTesting
({Map<String, String> folders, List<String>? favorited})?
normalizeFavoriteFoldersPayload(Object? value) {
  final data = comicSourceMapOrNull(value);
  if (data == null) {
    return null;
  }
  final folders = <String, String>{};
  final rawFolders = comicSourceMapOrNull(data["folders"]);
  if (rawFolders != null) {
    for (final entry in rawFolders.entries) {
      final folderName = entry.value;
      if (folderName == null) {
        continue;
      }
      folders[entry.key] = folderName.toString();
    }
  }
  return (
    folders: folders,
    favorited: data["favorited"] == null
        ? null
        : comicSourceStringList(data["favorited"]),
  );
}

@visibleForTesting
({bool multiFolder, bool? isOldToNewSort, bool singleFolderForSingleComic})
normalizeFavoriteDataFlags({
  required Object? multiFolder,
  required Object? isOldToNewSort,
  required Object? singleFolderForSingleComic,
}) {
  return (
    multiFolder: comicSourceBool(multiFolder) ?? false,
    isOldToNewSort: comicSourceBool(isOldToNewSort),
    singleFolderForSingleComic:
        comicSourceBool(singleFolderForSingleComic) ?? false,
  );
}

@visibleForTesting
RegExp? parseComicIdMatch(Object? value) {
  final pattern = comicSourceNullableString(value);
  if (pattern == null || pattern.isEmpty) {
    return null;
  }
  try {
    return RegExp(pattern);
  } catch (_) {
    return null;
  }
}

@visibleForTesting
Map<String, dynamic> normalizeImageLoadingConfigResult(Object? value) {
  if (value is! Map) {
    return <String, dynamic>{};
  }
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) {
      result[key] = entry.value;
    }
  }
  return result;
}

class ComicSourceParseException implements Exception {
  final String message;

  ComicSourceParseException(this.message);

  @override
  String toString() {
    return message;
  }
}

class ComicSourceParser {
  /// comic source key
  String? _key;

  String? _name;

  Future<ComicSource> createAndParse(String js, String fileName) async {
    if (!fileName.endsWith("js")) {
      fileName = "$fileName.js";
    }
    var file = File(FilePath.join(App.dataPath, "comic_source", fileName));
    if (file.existsSync()) {
      int i = 0;
      while (file.existsSync()) {
        file = File(
          FilePath.join(
            App.dataPath,
            "comic_source",
            "${fileName.split('.').first}($i).js",
          ),
        );
        i++;
      }
    }
    await file.writeAsString(js);
    try {
      return await parse(js, file.path);
    } catch (e) {
      await file.delete();
      rethrow;
    }
  }

  Future<ComicSource> parse(String js, String filePath) async {
    js = js.replaceAll("\r\n", "\n");
    final className = extractComicSourceClassName(js);
    if (className == null) {
      throw ComicSourceParseException("Invalid Content");
    }
    JsEngine().runCode("""(() => { $js
        this['temp'] = new $className()
      }).call()
    """, className);
    _name =
        JsEngine().runCode("this['temp'].name") ??
        (throw ComicSourceParseException('name is required'));
    var key =
        JsEngine().runCode("this['temp'].key") ??
        (throw ComicSourceParseException('key is required'));
    var version =
        JsEngine().runCode("this['temp'].version") ??
        (throw ComicSourceParseException('version is required'));
    var minAppVersion = JsEngine().runCode("this['temp'].minAppVersion");
    var url = JsEngine().runCode("this['temp'].url");
    if (minAppVersion != null) {
      if (compareSemVer(minAppVersion, App.version.split('-').first)) {
        throw ComicSourceParseException(
          "minAppVersion @version is required".tlParams({
            "version": minAppVersion,
          }),
        );
      }
    }
    for (var source in ComicSource.all()) {
      if (source.key == key) {
        throw ComicSourceParseException("key($key) already exists");
      }
    }
    _key = key;
    _checkKeyValidation();

    JsEngine().runCode("""
      ComicSource.sources.$_key = this['temp'];
    """);

    var source = ComicSource(
      _name!,
      key,
      _loadAccountConfig(),
      _loadCategoryData(),
      _loadCategoryComicsData(),
      _loadFavoriteData(),
      _loadExploreData(),
      _loadSearchData(),
      _parseSettings(),
      _parseLoadComicFunc(),
      _parseThumbnailLoader(),
      _parseLoadComicPagesFunc(),
      _parseImageLoadingConfigFunc(),
      _parseThumbnailLoadingConfigFunc(),
      filePath,
      url ?? "",
      version ?? "1.0.0",
      _parseCommentsLoader(),
      _parseSendCommentFunc(),
      _parseChapterCommentsLoader(),
      _parseSendChapterCommentFunc(),
      _parseLikeFunc(),
      _parseVoteCommentFunc(),
      _parseLikeCommentFunc(),
      _parseIdMatch(),
      _parseTranslation(),
      _parseClickTagEvent(),
      _parseTagSuggestionSelectFunc(),
      _parseLinkHandler(),
      _getValue("search.enableTagsSuggestions") ?? false,
      _getValue("comic.enableTagsTranslate") ?? false,
      _parseStarRatingFunc(),
      _parseArchiveDownloader(),
    );

    await source.loadData();

    if (_checkExists("init")) {
      Future.delayed(const Duration(milliseconds: 50), () {
        JsEngine().runCode("ComicSource.sources.$_key.init()");
      });
    }

    return source;
  }

  _checkKeyValidation() {
    // 仅允许数字和字母以及下划线
    if (!_key!.contains(RegExp(r"^[a-zA-Z0-9_]+$"))) {
      throw ComicSourceParseException("key $_key is invalid");
    }
  }

  bool _checkExists(String index) {
    return JsEngine().runCode(
      "ComicSource.sources.$_key.$index !== null "
      "&& ComicSource.sources.$_key.$index !== undefined",
    );
  }

  dynamic _getValue(String index) {
    return JsEngine().runCode("ComicSource.sources.$_key.$index");
  }

  AccountConfig? _loadAccountConfig() {
    if (!_checkExists("account")) {
      return null;
    }

    Future<Res<bool>> Function(String account, String pwd)? login;

    if (_checkExists("account.login")) {
      login = (account, pwd) async {
        try {
          await JsEngine().runCode("""
          ComicSource.sources.$_key.account.login(${jsonEncode(account)},
          ${jsonEncode(pwd)})
        """);
          var source = ComicSource.find(_key!)!;
          source.data["account"] = <String>[account, pwd];
          source.clearLoginExpired();
          source.saveDataInBackground();
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    }

    void logout() {
      JsEngine().runCode("ComicSource.sources.$_key.account.logout()");
    }

    bool Function(String url, String title)? checkLoginStatus;

    void Function()? onLoginSuccess;

    if (_checkExists('account.loginWithWebview')) {
      checkLoginStatus = (url, title) {
        try {
          final res = JsEngine().runCode("""
            ComicSource.sources.$_key.account.loginWithWebview.checkStatus(
              ${jsonEncode(url)}, ${jsonEncode(title)})
          """);
          return comicSourceBool(res) ?? false;
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return false;
        }
      };

      if (_checkExists('account.loginWithWebview.onLoginSuccess')) {
        onLoginSuccess = () {
          JsEngine().runCode("""
            ComicSource.sources.$_key.account.loginWithWebview.onLoginSuccess()
          """);
        };
      }
    }

    Future<bool> Function(List<String>)? validateCookies;

    if (_checkExists('account.loginWithCookies?.validate')) {
      validateCookies = (cookies) async {
        try {
          var res = await JsEngine().runCode("""
            ComicSource.sources.$_key.account.loginWithCookies.validate(${jsonEncode(cookies)})
          """);
          return comicSourceBool(res) ?? false;
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return false;
        }
      };
    }

    return AccountConfig(
      login,
      _getValue("account.loginWithWebview?.url"),
      _getValue("account.registerWebsite"),
      logout,
      checkLoginStatus,
      onLoginSuccess,
      comicSourceStringListOrNull(
        _getValue("account.loginWithCookies?.fields"),
      ),
      validateCookies,
    );
  }

  List<ExplorePageData> _loadExploreData() {
    if (!_checkExists("explore")) {
      return const [];
    }
    var length = JsEngine().runCode("ComicSource.sources.$_key.explore.length");
    var pages = <ExplorePageData>[];
    for (int i = 0; i < length; i++) {
      final definition = normalizeExplorePageDefinition(
        _getValue("explore[$i].title"),
        _getValue("explore[$i].type"),
      );
      if (definition == null) {
        continue;
      }
      final type = _getValue("explore[$i].type");
      Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;
      Future<Res<List<Comic>>> Function(int page)? loadPage;
      Future<Res<List<Comic>>> Function(String? next)? loadNext;
      Future<Res<List<Object>>> Function(int index)? loadMixed;
      if (type == "singlePageWithMultiPart") {
        loadMultiPart = () async {
          try {
            var res = await JsEngine().runCode(
              "ComicSource.sources.$_key.explore[$i].load()",
            );
            return Res(normalizeExplorePageParts(res, _key!));
          } catch (e, s) {
            Log.error("Data Analysis", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      } else if (type == "multiPageComicList") {
        if (_checkExists("explore[$i].load")) {
          loadPage = (int page) async {
            try {
              var res = await JsEngine().runCode(
                "ComicSource.sources.$_key.explore[$i].load(${jsonEncode(page)})",
              );
              final map = comicSourceMapOrNull(res);
              return Res(
                normalizeSourceComicList(map?["comics"], _key!),
                subData: map?["maxPage"],
              );
            } catch (e, s) {
              Log.error("Network", "$e\n$s");
              return Res.error(e.toString());
            }
          };
        } else {
          loadNext = (next) async {
            try {
              var res = await JsEngine().runCode(
                "ComicSource.sources.$_key.explore[$i].loadNext(${jsonEncode(next)})",
              );
              final map = comicSourceMapOrNull(res);
              return Res(
                normalizeSourceComicList(map?["comics"], _key!),
                subData: map?["next"],
              );
            } catch (e, s) {
              Log.error("Network", "$e\n$s");
              return Res.error(e.toString());
            }
          };
        }
      } else if (type == "multiPartPage") {
        loadMultiPart = () async {
          try {
            var res = await JsEngine().runCode(
              "ComicSource.sources.$_key.explore[$i].load()",
            );
            return Res(normalizeExplorePageParts(res, _key!));
          } catch (e, s) {
            Log.error("Data Analysis", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      } else if (type == 'mixed') {
        loadMixed = (index) async {
          try {
            var res = await JsEngine().runCode(
              "ComicSource.sources.$_key.explore[$i].load(${jsonEncode(index)})",
            );
            final map = comicSourceMapOrNull(res);
            return Res(
              normalizeMixedExploreData(map?['data'], _key!),
              subData: map?['maxPage'],
            );
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      pages.add(
        ExplorePageData(
          definition.title,
          definition.type,
          loadPage,
          loadNext,
          loadMultiPart,
          loadMixed,
        ),
      );
    }
    return pages;
  }

  CategoryData? _loadCategoryData() {
    var doc = _getValue("category");

    if (doc?["title"] == null) {
      return null;
    }

    final title = comicSourceString(doc["title"]);
    final enableRankingPage =
        comicSourceBool(doc["enableRankingPage"]) ?? false;

    var categoryParts = <BaseCategoryPart>[];

    final rawParts = doc["parts"];
    final parts = rawParts is Iterable ? rawParts : const [];
    for (var rawPart in parts) {
      final c = comicSourceMapOrNull(rawPart);
      if (c == null) {
        continue;
      }
      if (c["categories"] != null && c["categories"] is! List) {
        continue;
      }
      List? categories = c["categories"];
      if (isNewCategoryFormatList(categories)) {
        // new format
        final name = comicSourceString(c["name"]);
        final type = comicSourceString(c["type"]);
        final cs = normalizeDynamicCategoryItems(categories, _key!);
        if (type != "dynamic" && cs.isEmpty) {
          continue;
        }
        if (type == "fixed") {
          categoryParts.add(FixedCategoryPart(name, cs));
        } else if (type == "random") {
          categoryParts.add(
            RandomCategoryPart(
              name,
              cs,
              normalizeCategoryRandomNumber(c["randomNumber"]),
            ),
          );
        } else if (type == "dynamic" && categories == null) {
          var loader = c["loader"];
          if (loader is! JSInvokable) {
            throw "DynamicCategoryPart loader must be a function";
          }
          categoryParts.add(
            DynamicCategoryPart(name, JSAutoFreeFunction(loader), _key!),
          );
        }
      } else {
        // old format
        final name = comicSourceString(c["name"]);
        final type = comicSourceString(c["type"]);
        final tags = normalizeLegacyCategoryTags(c["categories"]);
        if (tags.isEmpty) {
          continue;
        }
        final itemType = comicSourceString(c["itemType"]);
        List<String>? categoryParams = comicSourceStringListOrNull(
          c["categoryParams"],
        );
        final groupParam = comicSourceNullableString(c["groupParam"]);
        if (groupParam != null) {
          categoryParams = List.filled(tags.length, groupParam);
        }
        var cs = <CategoryItem>[];
        for (int i = 0; i < tags.length; i++) {
          PageJumpTarget target;
          if (itemType == 'category') {
            target = PageJumpTarget(_key!, 'category', {
              "category": tags[i],
              "param": categoryParams?.elementAtOrNull(i),
            });
          } else if (itemType == 'search') {
            target = PageJumpTarget(_key!, 'search', {"keyword": tags[i]});
          } else if (itemType == 'search_with_namespace') {
            target = PageJumpTarget(_key!, 'search', {
              "keyword": "$name:$tags[i]",
            });
          } else {
            target = PageJumpTarget(_key!, itemType, null);
          }
          cs.add(CategoryItem(tags[i], target));
        }
        if (type == "fixed") {
          categoryParts.add(FixedCategoryPart(name, cs));
        } else if (type == "random") {
          categoryParts.add(
            RandomCategoryPart(
              name,
              cs,
              normalizeCategoryRandomNumber(c["randomNumber"]),
            ),
          );
        }
      }
    }

    return CategoryData(
      title: title,
      categories: categoryParts,
      enableRankingPage: enableRankingPage,
      key: title,
    );
  }

  CategoryComicsData? _loadCategoryComicsData() {
    if (!_checkExists("categoryComics")) return null;

    List<CategoryComicsOptions>? options;
    if (_checkExists("categoryComics.optionList")) {
      options = <CategoryComicsOptions>[];
      final rawOptions = _getValue("categoryComics.optionList");
      final optionItems = rawOptions is Iterable ? rawOptions : const [];
      for (var element in optionItems) {
        final option = normalizeCategoryComicsOptionsItem(element);
        if (option != null) {
          options.add(option);
        }
      }
    }

    CategoryOptionsLoader? optionLoader;
    if (_checkExists("categoryComics.optionLoader")) {
      optionLoader = (category, param) async {
        try {
          dynamic res = JsEngine().runCode("""
          ComicSource.sources.$_key.categoryComics.optionLoader(
            ${jsonEncode(category)}, ${jsonEncode(param)})
        """);
          if (res is Future) {
            res = await res;
          }
          if (res is! List) {
            return Res.error(
              "Invalid data:\nExpected: List\nGot: ${res.runtimeType}",
            );
          }
          var options = <CategoryComicsOptions>[];
          for (var element in res) {
            final option = normalizeCategoryComicsOptionsItem(element);
            if (option == null) {
              continue;
            }
            options.add(option);
          }
          return Res(options);
        } catch (e) {
          Log.error("Data Analysis", "Failed to load category options.\n$e");
          return Res.error(e.toString());
        }
      };
    }

    RankingData? rankingData;
    if (_checkExists("categoryComics.ranking")) {
      final options = parseCategoryOptionEntries(
        _getValue("categoryComics.ranking.options"),
      );
      Future<Res<List<Comic>>> Function(String option, int page)? load;
      Future<Res<List<Comic>>> Function(String option, String? next)?
      loadWithNext;
      if (_checkExists("categoryComics.ranking.load")) {
        load = (option, page) async {
          try {
            var res = await JsEngine().runCode("""
            ComicSource.sources.$_key.categoryComics.ranking.load(
              ${jsonEncode(option)}, ${jsonEncode(page)})
          """);
            return normalizeSourceComicListResult(res, _key!);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      } else {
        loadWithNext = (option, next) async {
          try {
            var res = await JsEngine().runCode("""
            ComicSource.sources.$_key.categoryComics.ranking.loadWithNext(
              ${jsonEncode(option)}, ${jsonEncode(next)})
          """);
            return normalizeSourceComicListResult(
              res,
              _key!,
              subDataKey: 'next',
            );
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      rankingData = RankingData(options, load, loadWithNext);
    }

    if (options == null && optionLoader == null) {
      options = [];
    }

    return CategoryComicsData(
      options: options,
      optionsLoader: optionLoader,
      load: (category, param, options, page) async {
        try {
          var res = await JsEngine().runCode("""
              ComicSource.sources.$_key.categoryComics.load(
                ${jsonEncode(category)},
                ${jsonEncode(param)},
                ${jsonEncode(options)},
                ${jsonEncode(page)}
              )
            """);
          return normalizeSourceComicListResult(res, _key!);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
      rankingData: rankingData,
    );
  }

  SearchPageData? _loadSearchData() {
    if (!_checkExists("search")) return null;
    var options = <SearchOptions>[];
    final rawOptions = _getValue("search.optionList");
    final optionItems = rawOptions is Iterable ? rawOptions : const [];
    for (var element in optionItems) {
      final option = normalizeSearchOptionsItem(element);
      if (option != null) {
        options.add(option);
      }
    }

    SearchFunction? loadPage;

    SearchNextFunction? loadNext;

    if (_checkExists('search.load')) {
      loadPage = (keyword, page, searchOption) async {
        try {
          var res = await JsEngine().runCode("""
          ComicSource.sources.$_key.search.load(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(page)})
        """);
          return normalizeSourceComicListResult(res, _key!);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    } else {
      loadNext = (keyword, next, searchOption) async {
        try {
          var res = await JsEngine().runCode("""
          ComicSource.sources.$_key.search.loadNext(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(next)})
        """);
          return normalizeSourceComicListResult(res, _key!, subDataKey: 'next');
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    }

    return SearchPageData(options, loadPage, loadNext);
  }

  LoadComicFunc? _parseLoadComicFunc() {
    return (id) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources.$_key.comic.loadInfo(${jsonEncode(id)})
        """);
        final details = normalizeComicDetailsPayload(
          res,
          sourceKey: _key!,
          comicId: id,
        );
        if (details == null) {
          return const Res.error("Invalid data");
        }
        return Res(details);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LoadComicPagesFunc? _parseLoadComicPagesFunc() {
    return (id, ep) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources.$_key.comic.loadEp(${jsonEncode(id)}, ${jsonEncode(ep)})
        """);
        return Res(comicSourceStringList(comicSourceMapOrNull(res)?["images"]));
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  FavoriteData? _loadFavoriteData() {
    if (!_checkExists("favorites")) return null;

    final favoriteFlags = normalizeFavoriteDataFlags(
      multiFolder: _getValue("favorites.multiFolder"),
      isOldToNewSort: _getValue("favorites.isOldToNewSort"),
      singleFolderForSingleComic: _getValue(
        "favorites.singleFolderForSingleComic",
      ),
    );

    Future<Res<T>> retryZone<T>(Future<Res<T>> Function() func) async {
      if (!ComicSource.find(_key!)!.isLogged) {
        return const Res.error("Not login");
      }
      var res = await func();
      if (res.error && res.errorMessage!.contains("Login expired")) {
        var source = ComicSource.find(_key!)!;
        var reLoginRes = await source.reLogin();
        if (!reLoginRes) {
          source.markLoginExpired();
          source.saveDataInBackground();
          return const Res.error("Login expired and re-login failed");
        } else {
          source.clearLoginExpired();
          return func();
        }
      }
      return res;
    }

    Future<Res<bool>> addOrDelFavFunc(
      String comicId,
      String folderId,
      bool isAdding,
      String? favId,
    ) async {
      func() async {
        try {
          await JsEngine().runCode("""
            ComicSource.sources.$_key.favorites.addOrDelFavorite(
              ${jsonEncode(comicId)}, ${jsonEncode(folderId)}, ${jsonEncode(isAdding)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res<bool>.error(e.toString());
        }
      }

      return retryZone(func);
    }

    Future<Res<List<Comic>>> Function(int page, [String? folder])? loadComic;

    Future<Res<List<Comic>>> Function(String? next, [String? folder])? loadNext;

    if (_checkExists("favorites.loadComics")) {
      loadComic = (int page, [String? folder]) async {
        Future<Res<List<Comic>>> func() async {
          try {
            var res = await JsEngine().runCode("""
            ComicSource.sources.$_key.favorites.loadComics(
              ${jsonEncode(page)}, ${jsonEncode(folder)})
          """);
            return normalizeSourceComicListResult(res, _key!);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        }

        return retryZone(func);
      };
    }

    if (_checkExists("favorites.loadNext")) {
      loadNext = (String? next, [String? folder]) async {
        Future<Res<List<Comic>>> func() async {
          try {
            var res = await JsEngine().runCode("""
            ComicSource.sources.$_key.favorites.loadNext(
              ${jsonEncode(next)}, ${jsonEncode(folder)})
          """);
            return normalizeSourceComicListResult(
              res,
              _key!,
              subDataKey: 'next',
            );
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        }

        return retryZone(func);
      };
    }

    Future<Res<Map<String, String>>> Function([String? comicId])? loadFolders;

    Future<Res<bool>> Function(String name)? addFolder;

    Future<Res<bool>> Function(String key)? deleteFolder;

    if (favoriteFlags.multiFolder) {
      loadFolders = ([String? comicId]) async {
        Future<Res<Map<String, String>>> func() async {
          try {
            var res = await JsEngine().runCode("""
            ComicSource.sources.$_key.favorites.loadFolders(${jsonEncode(comicId)})
          """);
            final folders = normalizeFavoriteFoldersPayload(res);
            if (folders == null) {
              return const Res.error("Invalid data");
            }
            return Res(folders.folders, subData: folders.favorited);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        }

        return retryZone(func);
      };
      if (_checkExists("favorites.addFolder")) {
        addFolder = (name) async {
          try {
            await JsEngine().runCode("""
            ComicSource.sources.$_key.favorites.addFolder(${jsonEncode(name)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
      if (_checkExists("favorites.deleteFolder")) {
        deleteFolder = (key) async {
          try {
            await JsEngine().runCode("""
            ComicSource.sources.$_key.favorites.deleteFolder(${jsonEncode(key)})
          """);
            return const Res(true);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.error(e.toString());
          }
        };
      }
    }

    return FavoriteData(
      key: _key!,
      title: _name!,
      multiFolder: favoriteFlags.multiFolder,
      loadComic: loadComic,
      loadNext: loadNext,
      loadFolders: loadFolders,
      addFolder: addFolder,
      deleteFolder: deleteFolder,
      addOrDelFavorite: addOrDelFavFunc,
      isOldToNewSort: favoriteFlags.isOldToNewSort,
      singleFolderForSingleComic: favoriteFlags.singleFolderForSingleComic,
    );
  }

  CommentsLoader? _parseCommentsLoader() {
    if (!_checkExists("comic.loadComments")) return null;
    return (id, subId, page, replyTo) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources.$_key.comic.loadComments(
            ${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(page)}, ${jsonEncode(replyTo)})
        """);
        final data = comicSourceMapOrNull(res);
        return Res(
          comicSourceMapList(
            data?["comments"],
          ).map((e) => Comment.fromJson(e)).toList(),
          subData: data?["maxPage"],
        );
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  SendCommentFunc? _parseSendCommentFunc() {
    if (!_checkExists("comic.sendComment")) return null;
    return (id, subId, content, replyTo) async {
      Future<Res<bool>> func() async {
        try {
          await JsEngine().runCode("""
            ComicSource.sources.$_key.comic.sendComment(
              ${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(content)}, ${jsonEncode(replyTo)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      }

      var res = await func();
      if (res.error && res.errorMessage!.contains("Login expired")) {
        var source = ComicSource.find(_key!)!;
        var reLoginRes = await source.reLogin();
        if (!reLoginRes) {
          source.markLoginExpired();
          source.saveDataInBackground();
          return const Res.error("Login expired and re-login failed");
        } else {
          source.clearLoginExpired();
          return func();
        }
      }
      return res;
    };
  }

  ChapterCommentsLoader? _parseChapterCommentsLoader() {
    if (!_checkExists("comic.loadChapterComments")) return null;
    return (comicId, epId, page, replyTo) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources.$_key.comic.loadChapterComments(
            ${jsonEncode(comicId)}, ${jsonEncode(epId)}, ${jsonEncode(page)}, ${jsonEncode(replyTo)})
        """);
        final data = comicSourceMapOrNull(res);
        return Res(
          comicSourceMapList(
            data?["comments"],
          ).map((e) => Comment.fromJson(e)).toList(),
          subData: data?["maxPage"],
        );
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  SendChapterCommentFunc? _parseSendChapterCommentFunc() {
    if (!_checkExists("comic.sendChapterComment")) return null;
    return (comicId, epId, content, replyTo) async {
      Future<Res<bool>> func() async {
        try {
          await JsEngine().runCode("""
            ComicSource.sources.$_key.comic.sendChapterComment(
              ${jsonEncode(comicId)}, ${jsonEncode(epId)}, ${jsonEncode(content)}, ${jsonEncode(replyTo)})
          """);
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      }

      var res = await func();
      if (res.error && res.errorMessage!.contains("Login expired")) {
        var source = ComicSource.find(_key!)!;
        var reLoginRes = await source.reLogin();
        if (!reLoginRes) {
          source.markLoginExpired();
          source.saveDataInBackground();
          return const Res.error("Login expired and re-login failed");
        } else {
          source.clearLoginExpired();
          return func();
        }
      }
      return res;
    };
  }

  GetImageLoadingConfigFunc? _parseImageLoadingConfigFunc() {
    if (!_checkExists("comic.onImageLoad")) {
      return null;
    }
    return (imageKey, comicId, ep) async {
      var res = JsEngine().runCode("""
          ComicSource.sources.$_key.comic.onImageLoad(
            ${jsonEncode(imageKey)}, ${jsonEncode(comicId)}, ${jsonEncode(ep)})
        """);
      if (res is Future) {
        return normalizeImageLoadingConfigResult(await res);
      }
      return normalizeImageLoadingConfigResult(res);
    };
  }

  GetThumbnailLoadingConfigFunc? _parseThumbnailLoadingConfigFunc() {
    if (!_checkExists("comic.onThumbnailLoad")) {
      return null;
    }
    return (imageKey) {
      var res = JsEngine().runCode("""
          ComicSource.sources.$_key.comic.onThumbnailLoad(${jsonEncode(imageKey)})
        """);
      return normalizeImageLoadingConfigResult(res);
    };
  }

  ComicThumbnailLoader? _parseThumbnailLoader() {
    if (!_checkExists("comic.loadThumbnails")) {
      return null;
    }
    return (id, next) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources.$_key.comic.loadThumbnails(${jsonEncode(id)}, ${jsonEncode(next)})
        """);
        final data = comicSourceMapOrNull(res);
        return Res(
          comicSourceStringList(data?['thumbnails']),
          subData: data?['next'],
        );
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LikeOrUnlikeComicFunc? _parseLikeFunc() {
    if (!_checkExists("comic.likeComic")) {
      return null;
    }
    return (id, isLiking) async {
      try {
        await JsEngine().runCode("""
          ComicSource.sources.$_key.comic.likeComic(${jsonEncode(id)}, ${jsonEncode(isLiking)})
        """);
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  VoteCommentFunc? _parseVoteCommentFunc() {
    if (!_checkExists("comic.voteComment")) {
      return null;
    }
    return (id, subId, commentId, isUp, isCancel) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources.$_key.comic.voteComment(${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(commentId)}, ${jsonEncode(isUp)}, ${jsonEncode(isCancel)})
        """);
        return Res(res is num ? res.toInt() : 0);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LikeCommentFunc? _parseLikeCommentFunc() {
    if (!_checkExists("comic.likeComment")) {
      return null;
    }
    return (id, subId, commentId, isLiking) async {
      try {
        var res = await JsEngine().runCode("""
          ComicSource.sources.$_key.comic.likeComment(${jsonEncode(id)}, ${jsonEncode(subId)}, ${jsonEncode(commentId)}, ${jsonEncode(isLiking)})
        """);
        return Res(res is num ? res.toInt() : 0);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  Map<String, Map<String, dynamic>> _parseSettings() {
    return normalizeSourceSettings(_getValue("settings"));
  }

  RegExp? _parseIdMatch() {
    if (!_checkExists("comic.idMatch")) {
      return null;
    }
    return parseComicIdMatch(_getValue("comic.idMatch"));
  }

  Map<String, Map<String, String>>? _parseTranslation() {
    if (!_checkExists("translation")) {
      return null;
    }
    var data = _getValue("translation");
    var res = <String, Map<String, String>>{};
    if (data is! Map) {
      return res;
    }
    for (var e in data.entries) {
      final key = e.key;
      final value = e.value;
      if (key is! String || value is! Map) {
        continue;
      }
      final normalized = <String, String>{};
      for (final entry in value.entries) {
        final entryKey = entry.key;
        final entryValue = entry.value;
        if (entryKey is String && entryValue != null) {
          normalized[entryKey] = entryValue.toString();
        }
      }
      res[key] = normalized;
    }
    return res;
  }

  HandleClickTagEvent? _parseClickTagEvent() {
    if (!_checkExists("comic.onClickTag")) {
      return null;
    }
    return (namespace, tag) {
      var res = JsEngine().runCode("""
          ComicSource.sources.$_key.comic.onClickTag(${jsonEncode(namespace)}, ${jsonEncode(tag)})
        """);
      var r = comicSourceMapOrNull(res);
      if (r == null) {
        return null;
      }
      r.removeWhere((key, value) => value == null);
      return PageJumpTarget.parse(_key!, r);
    };
  }

  TagSuggestionSelectFunc? _parseTagSuggestionSelectFunc() {
    if (!_checkExists("search.onTagSuggestionSelected")) {
      return null;
    }
    return (namespace, tag) {
      var res = JsEngine().runCode("""
          ComicSource.sources.$_key.search.onTagSuggestionSelected(
            ${jsonEncode(namespace)}, ${jsonEncode(tag)})
        """);
      return res is String ? res : "$namespace:$tag";
    };
  }

  LinkHandler? _parseLinkHandler() {
    if (!_checkExists("comic.link")) {
      return null;
    }
    final domains = comicSourceStringList(_getValue("comic.link.domains"));
    linkToId(String link) {
      var res = JsEngine().runCode("""
          ComicSource.sources.$_key.comic.link.linkToId(${jsonEncode(link)})
        """);
      return res is String ? res : null;
    }

    return LinkHandler(domains, linkToId);
  }

  StarRatingFunc? _parseStarRatingFunc() {
    if (!_checkExists("comic.starRating")) {
      return null;
    }
    return (id, rating) async {
      try {
        await JsEngine().runCode("""
          ComicSource.sources.$_key.comic.starRating(${jsonEncode(id)}, ${jsonEncode(rating)})
        """);
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  ArchiveDownloader? _parseArchiveDownloader() {
    if (!_checkExists("comic.archive")) {
      return null;
    }
    return ArchiveDownloader(
      (cid) async {
        try {
          var res = await JsEngine().runCode("""
              ComicSource.sources.$_key.comic.archive.getArchives(${jsonEncode(cid)})
            """);
          return Res(
            comicSourceMapList(
              res,
            ).map((e) => ArchiveInfo.fromJson(e)).toList(),
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
      (cid, aid) async {
        try {
          var res = await JsEngine().runCode("""
              ComicSource.sources.$_key.comic.archive.getDownloadUrl(${jsonEncode(cid)}, ${jsonEncode(aid)})
            """);
          final url = comicSourceNullableString(res);
          if (url == null || url.isEmpty) {
            return const Res.error("Invalid archive download url");
          }
          return Res(url);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
    );
  }
}
