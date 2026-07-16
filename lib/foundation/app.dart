import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/history.dart';

import 'appdata.dart';
import 'favorites.dart';
import 'local.dart';

export "widget_utils.dart";
export "context.dart";

@visibleForTesting
Locale? resolveConfiguredLocale(Object? languageSetting) {
  return switch (languageSetting) {
    'zh-CN' => const Locale('zh', 'CN'),
    'zh-TW' => const Locale('zh', 'TW'),
    'en-US' => const Locale('en', 'US'),
    'en' => const Locale('en'),
    _ => null,
  };
}

@visibleForTesting
String resolveAndroidExternalStoragePath(
  String? externalPath,
  String dataPath,
) {
  if (externalPath == null || externalPath.isEmpty) {
    return dataPath;
  }
  return externalPath;
}

class _App {
  final version = "1.6.32";

  bool get isAndroid => Platform.isAndroid;

  bool get isIOS => Platform.isIOS;

  bool get isWindows => Platform.isWindows;

  bool get isLinux => Platform.isLinux;

  bool get isMacOS => Platform.isMacOS;

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Whether the app has been initialized.
  // If current Isolate is main Isolate, this value is always true.
  bool isInitialized = false;

  Locale get locale {
    Locale deviceLocale = PlatformDispatcher.instance.locale;
    if (deviceLocale.languageCode == "zh" &&
        deviceLocale.scriptCode == "Hant") {
      deviceLocale = const Locale("zh", "TW");
    }
    return resolveConfiguredLocale(appdata.settings['language']) ??
        deviceLocale;
  }

  late String dataPath;
  late String cachePath;
  String? externalStoragePath;

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  Future<BuildContext?> waitForMainNavigatorContext({
    Duration timeout = const Duration(seconds: 2),
    Duration interval = const Duration(milliseconds: 50),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final context = mainNavigatorKey?.currentContext;
      if (context != null && context.mounted) {
        return context;
      }
      await Future.delayed(interval);
    }
    final context = mainNavigatorKey?.currentContext;
    return context != null && context.mounted ? context : null;
  }

  final Appdata data = appdata;

  final HistoryManager history = HistoryManager();

  final LocalFavoritesManager favorites = LocalFavoritesManager();

  final LocalManager local = LocalManager();

  void rootPop() {
    rootNavigatorKey.currentState?.maybePop();
  }

  void pop() {
    if (rootNavigatorKey.currentState?.canPop() ?? false) {
      rootNavigatorKey.currentState?.pop();
    } else if (mainNavigatorKey?.currentState?.canPop() ?? false) {
      mainNavigatorKey?.currentState?.pop();
    }
  }

  Future<void> init() async {
    cachePath = (await getApplicationCacheDirectory()).path;
    dataPath = (await getApplicationSupportDirectory()).path;
    if (isAndroid) {
      externalStoragePath = resolveAndroidExternalStoragePath(
        (await getExternalStorageDirectory())?.path,
        dataPath,
      );
    }
    isInitialized = true;
  }

  Future<void> initComponents() async {
    await Future.wait([
      data.init(),
      history.init(),
      favorites.init(),
      local.init(),
    ]);
  }

  VoidCallback? _forceRebuildHandler;

  void registerForceRebuild(VoidCallback handler) {
    _forceRebuildHandler = handler;
  }

  void unregisterForceRebuild(VoidCallback handler) {
    if (identical(_forceRebuildHandler, handler)) {
      _forceRebuildHandler = null;
    }
  }

  @visibleForTesting
  bool get hasForceRebuildHandler => _forceRebuildHandler != null;

  void forceRebuild() {
    _forceRebuildHandler?.call();
  }
}

// ignore: non_constant_identifier_names
final App = _App();
