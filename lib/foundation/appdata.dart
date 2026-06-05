import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart';

@visibleForTesting
String normalizeDisableSyncFields(Object? value) {
  return value is String ? value : '';
}

@visibleForTesting
String normalizeDeviceId(Object? value) {
  return value is String ? value : '';
}

int normalizeDataVersion(Object? value) {
  final parsed = switch (value) {
    int() => value,
    String() => int.tryParse(value),
    _ => null,
  };
  if (parsed == null || parsed < 0) {
    return 0;
  }
  return parsed;
}

@visibleForTesting
List<String> normalizeSearchHistory(Object? value) {
  if (value is! Iterable) {
    return <String>[];
  }
  return value.whereType<String>().where((e) => e.isNotEmpty).take(50).toList();
}

@visibleForTesting
Map<String, dynamic> normalizeImplicitData(Object? value) {
  if (value is! Map) {
    return <String, dynamic>{};
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

@visibleForTesting
List<String> normalizeStringListSetting(Object? value) {
  if (value is! Iterable) {
    return <String>[];
  }
  return value
      .whereType<String>()
      .where((element) => element.isNotEmpty)
      .toList();
}

String normalizeStringSetting(Object? value, String fallback) {
  if (value is String) {
    return value;
  }
  return fallback;
}

bool normalizeBoolSetting(Object? value, bool fallback) {
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
  return fallback;
}

num normalizeNumSetting(Object? value, num fallback) {
  final parsed = switch (value) {
    num() => value,
    String() => num.tryParse(value),
    _ => null,
  };
  return parsed ?? fallback;
}

class Appdata with Init {
  Appdata._create();

  final Settings settings = Settings._create();

  var searchHistory = <String>[];

  bool _isSavingData = false;

  Future<void> saveData([bool sync = true]) async {
    while (_isSavingData) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _isSavingData = true;
    try {
      var futures = <Future>[];
      var json = toJson();
      var disableSyncFields = normalizeDisableSyncFields(
        json["settings"]["disableSyncFields"],
      );
      json["settings"]["disableSyncFields"] = disableSyncFields;
      var data = jsonEncode(json);
      var file = File(FilePath.join(App.dataPath, 'appdata.json'));
      futures.add(file.writeAsString(data));
      var syncFile = File(FilePath.join(App.dataPath, 'syncdata.json'));

      if (disableSyncFields.isNotEmpty) {
        var json4sync = jsonDecode(data);
        List<String> customDisableSync = splitField(disableSyncFields);
        for (var field in customDisableSync) {
          json4sync["settings"].remove(field);
        }
        var data4sync = jsonEncode(json4sync);
        futures.add(syncFile.writeAsString(data4sync));
      } else {
        futures.add(syncFile.deleteIgnoreError());
      }

      await Future.wait(futures);
    } finally {
      _isSavingData = false;
    }
    if (sync) {
      DataSync().uploadData();
    }
  }

  void saveDataInBackground([bool sync = true]) {
    unawaited(
      saveData(sync).catchError((Object error, StackTrace stackTrace) {
        Log.error("Appdata", "Failed to save app data: $error\n$stackTrace");
      }),
    );
  }

  void addSearchHistory(String keyword) {
    if (searchHistory.contains(keyword)) {
      searchHistory.remove(keyword);
    }
    searchHistory.insert(0, keyword);
    if (searchHistory.length > 50) {
      searchHistory.removeLast();
    }
    saveDataInBackground();
  }

  void removeSearchHistory(String keyword) {
    searchHistory.remove(keyword);
    saveDataInBackground();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    saveDataInBackground();
  }

  Map<String, dynamic> toJson() {
    return {'settings': settings._data, 'searchHistory': searchHistory};
  }

  List<String> splitField(String merged) {
    return merged
        .split(',')
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
  }

  /// Following fields are related to device-specific data and should not be synced.
  static const _disableSync = [
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "disableSyncFields",
    "deviceId",
  ];

  /// Sync data from another device
  void syncData(Map<String, dynamic> data) {
    final remoteSettings = data['settings'];
    if (remoteSettings is Map) {
      List<String> customDisableSync = splitField(
        normalizeDisableSyncFields(settings["disableSyncFields"]),
      );

      for (var entry in remoteSettings.entries) {
        final key = entry.key;
        if (key is! String) {
          continue;
        }
        if (!_disableSync.contains(key) && !customDisableSync.contains(key)) {
          settings[key] = entry.value;
        }
      }
    }
    searchHistory = normalizeSearchHistory(data['searchHistory']);
    saveDataInBackground();
  }

  var implicitData = <String, dynamic>{};

  Future<void> writeImplicitData() async {
    try {
      while (_isSavingData) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      _isSavingData = true;
      try {
        var file = File(FilePath.join(App.dataPath, 'implicitData.json'));
        await file.writeAsString(jsonEncode(implicitData));
      } finally {
        _isSavingData = false;
      }
    } catch (e, s) {
      Log.error("Appdata", "Failed to save implicit data: $e", s);
    }
  }

  @override
  Future<void> doInit() async {
    var dataPath = (await getApplicationSupportDirectory()).path;
    var file = File(FilePath.join(dataPath, 'appdata.json'));
    if (!await file.exists()) {
      return;
    }
    try {
      var json = jsonDecode(await file.readAsString());
      if (json is! Map) {
        throw const FormatException('appdata root must be an object');
      }
      final storedSettings = json['settings'];
      if (storedSettings is Map) {
        for (var entry in storedSettings.entries) {
          final key = entry.key;
          if (key is String && entry.value != null) {
            settings[key] = entry.value;
          }
        }
      }
      searchHistory = normalizeSearchHistory(json['searchHistory']);
    } catch (e) {
      Log.error("Appdata", "Failed to load appdata", e);
      Log.info("Appdata", "Resetting appdata");
      file.deleteIgnoreError();
    }
    if (normalizeDeviceId(settings["deviceId"]).isEmpty) {
      settings._data["deviceId"] = const Uuid().v4();
      await saveData(false);
    }
    try {
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      if (await implicitDataFile.exists()) {
        implicitData = normalizeImplicitData(
          jsonDecode(await implicitDataFile.readAsString()),
        );
      }
    } catch (e) {
      Log.error("Appdata", "Failed to load implicit data", e);
      Log.info("Appdata", "Resetting implicit data");
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      implicitDataFile.deleteIgnoreError();
    }
  }
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create();

  final _data = <String, dynamic>{
    'comicDisplayMode': 'detailed', // detailed, brief
    'comicTileScale': 1.00, // 0.75-1.25
    'color': 'system', // red, pink, purple, green, orange, blue
    'theme_mode': 'system', // light, dark, system
    'newFavoriteAddTo': 'end', // start, end
    'moveFavoriteAfterRead': 'none', // none, end, start
    'proxy': 'system', // direct, system, proxy string
    'explore_pages': [],
    'categories': [],
    'favorites': [],
    'searchSources': null,
    'showFavoriteStatusOnTile': true,
    'showHistoryStatusOnTile': false,
    'blockedWords': [],
    'blockedCommentWords': [],
    'defaultSearchTarget': null,
    'autoPageTurningInterval': 5, // in seconds
    'readerMode': 'galleryLeftToRight', // values of [ReaderMode]
    'readerScreenPicNumberForLandscape': 1, // 1 - 5
    'readerScreenPicNumberForPortrait': 1, // 1 - 5
    'enableTapToTurnPages': true,
    'reverseTapToTurnPages': false,
    'enablePageAnimation': true,
    'language': 'system', // system, zh-CN, zh-TW, en-US
    'cacheSize': 2048, // in MB
    'downloadThreads': 5,
    'enableLongPressToZoom': true,
    'longPressZoomPosition': "press", // press, center
    'checkUpdateOnStart': false,
    'limitImageWidth': true,
    'webdav': [], // empty means not configured
    "disableSyncFields": "", // "field1, field2, ..."
    'dataVersion': 0,
    'quickFavorite': null,
    'enableTurnPageByVolumeKey': true,
    'enableClockAndBatteryInfoInReader': true,
    'quickCollectImage': 'No', // No, DoubleTap, Swipe
    'authorizationRequired': false,
    'onClickFavorite': 'viewDetail', // viewDetail, read
    'enableDnsOverrides': false,
    'dnsOverrides': {},
    'enableCustomImageProcessing': false,
    'customImageProcessing': defaultCustomImageProcessing,
    'sni': true,
    'autoAddLanguageFilter': 'none', // none, chinese, english, japanese
    'comicSourceListUrl': _defaultSourceListUrl,
    'preloadImageCount': 4,
    'followUpdatesFolder': null,
    'initialPage': '0',
    'comicListDisplayMode': 'paging', // paging, continuous
    'showPageNumberInReader': true,
    'showSingleImageOnFirstPage': false,
    'enableDoubleTapToZoom': true,
    'reverseChapterOrder': false,
    'showSystemStatusBar': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
    'ignoreBadCertificate': false,
    'readerScrollSpeed': 1.0, // 0.5 - 3.0
    'localFavoritesFirst': true,
    'autoCloseFavoritePanel': false,
    'showChapterComments': true, // show chapter comments in reader
    'showChapterCommentsAtEnd':
        false, // show chapter comments at end of chapter
    'autoDeleteReadChapters': false,
  };

  operator [](String key) {
    return _data[key];
  }

  operator []=(String key, dynamic value) {
    _data[key] = value;
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  List<String> stringList(String key) {
    return normalizeStringListSetting(_data[key]);
  }

  String stringValue(String key, {required String fallback}) {
    return normalizeStringSetting(_data[key], fallback);
  }

  bool boolValue(String key, {required bool fallback}) {
    return normalizeBoolSetting(_data[key], fallback);
  }

  Map<String, dynamic> _copyStringDynamicMap(Map value) {
    final normalized = <String, dynamic>{};
    for (final entry in value.entries) {
      final entryKey = entry.key;
      if (entryKey is String) {
        normalized[entryKey] = entry.value;
      }
    }
    return normalized;
  }

  Map<String, dynamic> _stringDynamicMap(String key) {
    final value = _data[key];
    var normalized = <String, dynamic>{};
    if (value is Map) {
      normalized = _copyStringDynamicMap(value);
    }
    _data[key] = normalized;
    return normalized;
  }

  Map<String, dynamic>? _nestedStringDynamicMap(String key, String nestedKey) {
    final value = _stringDynamicMap(key)[nestedKey];
    if (value is Map) {
      final normalized = _copyStringDynamicMap(value);
      _stringDynamicMap(key)[nestedKey] = normalized;
      return normalized;
    }
    return null;
  }

  Map<String, dynamic> _ensureNestedStringDynamicMap(
    String key,
    String nestedKey,
  ) {
    final existing = _nestedStringDynamicMap(key, nestedKey);
    if (existing != null) {
      return existing;
    }
    final created = <String, dynamic>{};
    _stringDynamicMap(key)[nestedKey] = created;
    return created;
  }

  int intValue(String key, {required int fallback, int? min, int? max}) {
    var value = normalizeNumSetting(_data[key], fallback).toInt();
    if (min != null && value < min) {
      value = min;
    }
    if (max != null && value > max) {
      value = max;
    }
    return value;
  }

  double doubleValue(
    String key, {
    required double fallback,
    double? min,
    double? max,
  }) {
    var value = normalizeNumSetting(_data[key], fallback).toDouble();
    if (min != null && value < min) {
      value = min;
    }
    if (max != null && value > max) {
      value = max;
    }
    return value;
  }

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _nestedStringDynamicMap(
          'comicSpecificSettings',
          "$comicId@$sourceKey",
        )?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue = _nestedStringDynamicMap(
        'comicSpecificSettings',
        "$comicId@$sourceKey",
      )?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    _ensureNestedStringDynamicMap(
      'comicSpecificSettings',
      "$comicId@$sourceKey",
    )[key] = value;
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    _stringDynamicMap('comicSpecificSettings').remove(key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = normalizeDeviceId(_data['deviceId']);
    if (deviceId.isEmpty) {
      return false;
    }
    return _nestedStringDynamicMap(
          'deviceSpecificSettings',
          deviceId,
        )?["enabled"] ==
        true;
  }

  dynamic getDeviceReaderSetting(String key) {
    if (!isDeviceSpecificSettingsEnabled()) {
      return _data[key];
    }
    var deviceId = normalizeDeviceId(_data['deviceId']);
    return _nestedStringDynamicMap('deviceSpecificSettings', deviceId)?[key] ??
        _data[key];
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    _ensureNestedStringDynamicMap('deviceSpecificSettings', deviceId)[key] =
        value;
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    var deviceId = normalizeDeviceId(_data['deviceId']);
    if (deviceId.isEmpty) {
      return;
    }
    _stringDynamicMap('deviceSpecificSettings').remove(deviceId);
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    var deviceId = normalizeDeviceId(_data['deviceId']);
    if (deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  @override
  String toString() {
    return _data.toString();
  }
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';

const _defaultSourceListUrl =
    "https://cdn.jsdelivr.net/gh/cyc20050130/venera-configs@main/index.json";
