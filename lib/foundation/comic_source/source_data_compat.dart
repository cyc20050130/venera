part of 'comic_source.dart';

Map<String, dynamic> _asSourceDataMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.from(value);
  }
  if (value is Map) {
    return Map<String, dynamic>.from(
      value.map((key, value) => MapEntry(key.toString(), value)),
    );
  }
  return <String, dynamic>{};
}

extension ComicSourceDataCompat on ComicSource {
  Map<String, dynamic> normalizeSourceData(Map<String, dynamic> rawData) {
    final normalized = _asSourceDataMap(rawData);
    final settingsData = _asSourceDataMap(normalized["settings"]);
    final sourceSettings = settings ?? const <String, Map<String, dynamic>>{};

    for (final entry in sourceSettings.entries) {
      final config = _asSourceDataMap(entry.value);
      if (!settingsData.containsKey(entry.key) &&
          config.containsKey("default")) {
        settingsData[entry.key] = config["default"];
      }
    }

    normalized["settings"] = settingsData;
    normalized["_loginExpired"] ??= false;

    switch (key) {
      case "jm":
        normalized["uid"] ??= "";
        normalized["lastCheckInDate"] ??= "";
        settingsData["apiDomain"] ??= "1";
        settingsData["imageStream"] ??= "1";
        settingsData["refreshDomainsOnStart"] ??= true;
        settingsData["favoriteOrder"] ??= "mr";
      case "komga":
        settingsData["base_url"] ??= "https://demo.komga.org";
        normalized["komga_libraries"] ??= <dynamic>[];
        normalized["komga_tags"] ??= <dynamic>[];
        normalized["komga_genres"] ??= <dynamic>[];
        normalized["komga_languages"] ??= <dynamic>[];
        normalized["komga_collections"] ??= <dynamic>[];
      case "lanraragi":
        normalized["categories"] ??= <dynamic>[];
        normalized["categories_ts"] ??= 0;
      case "kavita":
        normalized["kavita_libraries"] ??= <dynamic>[];
        normalized["kavita_genres"] ??= <dynamic>[];
        normalized["kavita_authors"] ??= <dynamic>[];
    }

    return normalized;
  }
}
