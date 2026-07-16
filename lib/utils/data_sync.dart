import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/data.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

List<String>? normalizeWebDavConfig(Object? config) {
  if (config is! List) {
    return null;
  }
  if (config.isEmpty) {
    return [];
  }
  if (config.length != 3 || config.whereType<String>().length != 3) {
    return null;
  }
  return config.cast<String>().toList();
}

bool normalizeWebDavAutoSync(Object? value, {bool fallback = false}) {
  return value is bool ? value : fallback;
}

@visibleForTesting
String? cacheFileNameForRemoteDataFile(Object? name) {
  if (name is! String || !name.endsWith('.venera')) {
    return null;
  }
  try {
    final sanitized = sanitizeFileName(name);
    return sanitized.endsWith('.venera') ? sanitized : null;
  } catch (_) {
    return null;
  }
}

@visibleForTesting
bool isUsableRemoteDataFileName(Object? name) {
  if (name is! String) {
    return false;
  }
  return cacheFileNameForRemoteDataFile(name) == name;
}

typedef RemoteDataFileInfo = ({
  String remoteName,
  String cacheName,
  String prefix,
  int? numericPrefix,
  int version,
});

@visibleForTesting
RemoteDataFileInfo? remoteDataFileInfoForName(Object? name) {
  if (!isUsableRemoteDataFileName(name)) {
    return null;
  }
  final remoteName = name as String;
  final baseName = remoteName.substring(
    0,
    remoteName.length - '.venera'.length,
  );
  final separator = baseName.lastIndexOf('-');
  if (separator <= 0 || separator >= baseName.length - 1) {
    return null;
  }
  final prefix = baseName.substring(0, separator);
  final numericPrefix = int.tryParse(prefix);
  final version = int.tryParse(baseName.substring(separator + 1));
  if (version == null || version < 0) {
    return null;
  }
  return (
    remoteName: remoteName,
    cacheName: cacheFileNameForRemoteDataFile(remoteName)!,
    prefix: prefix,
    numericPrefix: numericPrefix == null || numericPrefix < 0
        ? null
        : numericPrefix,
    version: version,
  );
}

int _compareRemoteDataFileAge(RemoteDataFileInfo a, RemoteDataFileInfo b) {
  final aPrefix = a.numericPrefix;
  final bPrefix = b.numericPrefix;
  if (aPrefix != null && bPrefix != null) {
    final prefixCompare = aPrefix.compareTo(bPrefix);
    if (prefixCompare != 0) {
      return prefixCompare;
    }
  } else {
    final prefixCompare = a.prefix.compareTo(b.prefix);
    if (prefixCompare != 0) {
      return prefixCompare;
    }
  }
  final versionCompare = a.version.compareTo(b.version);
  if (versionCompare != 0) {
    return versionCompare;
  }
  return a.remoteName.compareTo(b.remoteName);
}

int _compareRemoteDataFileFreshness(
  RemoteDataFileInfo a,
  RemoteDataFileInfo b,
) {
  final versionCompare = a.version.compareTo(b.version);
  if (versionCompare != 0) {
    return versionCompare;
  }
  return _compareRemoteDataFileAge(a, b);
}

@visibleForTesting
String? latestRemoteDataFileName(Iterable<Object?> names) {
  final files = names
      .map(remoteDataFileInfoForName)
      .whereType<RemoteDataFileInfo>()
      .toList();
  if (files.isEmpty) {
    return null;
  }
  files.sort(_compareRemoteDataFileFreshness);
  return files.last.remoteName;
}

@visibleForTesting
List<String> remoteDataFilesToRemoveBeforeUpload(
  Iterable<Object?> names,
  String currentDayPrefix, {
  int maxFiles = 10,
}) {
  final filesByName = <String, RemoteDataFileInfo>{};
  for (final name in names) {
    final file = remoteDataFileInfoForName(name);
    if (file != null) {
      filesByName[file.remoteName] = file;
    }
  }
  final files = filesByName.values.toList()..sort(_compareRemoteDataFileAge);

  if (maxFiles <= 0) {
    return files.map((file) => file.remoteName).toList();
  }

  final toRemove = <String>[];

  final currentPrefix = currentDayPrefix.endsWith('-')
      ? currentDayPrefix.substring(0, currentDayPrefix.length - 1)
      : currentDayPrefix;
  final samePrefixFiles = files
      .where((file) => file.prefix == currentPrefix)
      .toList();
  for (final file in samePrefixFiles) {
    files.remove(file);
    toRemove.add(file.remoteName);
  }

  while (files.length + 1 > maxFiles) {
    toRemove.add(files.removeAt(0).remoteName);
  }

  return toRemove;
}

@visibleForTesting
Future<void> uploadRemoteBackupSafely({
  required Future<void> Function() upload,
  required Iterable<String> filesToRemove,
  required Future<void> Function(String fileName) remove,
  void Function(String fileName, Object error, StackTrace stackTrace)?
  onRemoveError,
}) async {
  await upload();
  for (final fileName in filesToRemove) {
    try {
      await remove(fileName);
    } catch (error, stackTrace) {
      onRemoveError?.call(fileName, error, stackTrace);
    }
  }
}

class DataSync with ChangeNotifier {
  DataSync._() {
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        final context = App.rootNavigatorKey.currentContext;
        if (context == null || !context.mounted) {
          return;
        }
        WindowFrame.maybeOf(context)?.addCloseListener(_handleWindowClose);
      });
    }
  }

  void onDataChanged() {
    if (isEnabled) {
      uploadData();
    }
  }

  bool _handleWindowClose() {
    if (_isUploading) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    try {
      showLoadingDialog(
        App.rootContext,
        cancelButtonText: "Shut Down".tl,
        onCancel: () => exit(0),
        barrierDismissible: false,
        message: "Uploading data...".tl,
      );
      while (_isUploading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } catch (e, s) {
      Log.error("Data Sync", "Failed while waiting for upload on close: $e", s);
    }
    exit(0);
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  bool _haveWaitingTask = false;

  String? _lastError;

  String? get lastError => _lastError;

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = normalizeWebDavAutoSync(
      appdata.implicitData['webdavAutoSync'],
    );
    return autoSync && (normalizeWebDavConfig(config)?.isNotEmpty ?? false);
  }

  List<String>? _validateConfig() {
    return normalizeWebDavConfig(appdata.settings['webdav']);
  }

  Future<Res<bool>> uploadData() async {
    if (isDownloading) return const Res(true);
    if (_haveWaitingTask) return const Res(true);
    while (isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(),
      );

      File? data;
      try {
        final dataVersion =
            normalizeDataVersion(appdata.settings['dataVersion']) + 1;
        appdata.settings['dataVersion'] = dataVersion;
        await appdata.saveData(false);
        data = await exportAppData(
          appdata.settings['disableSyncFields'].toString().isNotEmpty,
        );
        var time = (DateTime.now().millisecondsSinceEpoch ~/ 86400000)
            .toString();
        var filename = time;
        filename += '-';
        filename += dataVersion.toString();
        filename += '.venera';
        var files = await client.readDir('/');
        final fileNames = files
            .map((file) => file.name)
            .where(isUsableRemoteDataFileName)
            .cast<String>()
            .toList();
        final filesToRemove = remoteDataFilesToRemoveBeforeUpload(
          fileNames,
          "$time-",
        );
        await uploadRemoteBackupSafely(
          upload: () async {
            await client.write(filename, await data!.readAsBytes());
          },
          filesToRemove: filesToRemove,
          remove: client.remove,
          onRemoveError: (fileName, error, stackTrace) {
            Log.warning(
              'Upload Data',
              'New backup was uploaded, but old remote backup '
                  '$fileName could not be removed: $error\n$stackTrace',
            );
          },
        );
        Log.info("Upload Data", "Data uploaded successfully");
        return const Res(true);
      } catch (e, s) {
        Log.error("Upload Data", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      } finally {
        await data?.deleteIgnoreError();
      }
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData() async {
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(),
      );

      File? localFile;
      try {
        var files = await client.readDir('/');
        final candidates =
            files
                .map((file) => remoteDataFileInfoForName(file.name))
                .whereType<RemoteDataFileInfo>()
                .toList()
              ..sort(_compareRemoteDataFileFreshness);
        var file = candidates.lastOrNull;
        if (file == null) {
          throw 'No data file found';
        }
        final remoteVersion = file.version;
        final currentVersion = normalizeDataVersion(
          appdata.settings['dataVersion'],
        );
        if (remoteVersion <= currentVersion) {
          Log.info("Data Sync", 'No new data to download');
          return const Res(true);
        }
        Log.info("Data Sync", "Downloading data from WebDAV server");
        localFile = File(FilePath.join(App.cachePath, file.cacheName));
        await client.read2File(file.remoteName, localFile.path);
        await importAppData(localFile, true);
        Log.info("Data Sync", "Data downloaded successfully");
        return const Res(true);
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      } finally {
        await localFile?.deleteIgnoreError();
      }
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }
}
