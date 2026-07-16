import 'dart:async';
import 'dart:io';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/core/database/backup_import_coordinator.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/perf_trace.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/handle_text_share.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'package:flutter_saf/flutter_saf.dart';

enum BootstrapPhase { idle, phaseA, phaseB, phaseC, ready }

final bootstrapController = BootstrapController();

const Duration _kLifecycleResumeQuietWindow = Duration(milliseconds: 900);
const int _kDefaultCacheSizeMb = 2048;

@visibleForTesting
int normalizeCacheSizeMb(Object? value) {
  final normalized = normalizeNumSetting(value, _kDefaultCacheSizeMb).toInt();
  return normalized > 0 ? normalized : _kDefaultCacheSizeMb;
}

@visibleForTesting
bool shouldCheckUpdateOnStart(Object? value) {
  return normalizeBoolSetting(value, false);
}

extension _FutureBootstrapInit<T> on Future<T> {
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("bootstrap", "$e\n$s");
    }
  }
}

void logBootstrapEvent(String label) {
  bootstrapController.logPerf(label);
}

Future<void> guardBootstrapTask(Future<void> future) async {
  await future.wait();
}

void installFlutterErrorLogger({
  void Function(String title, Object? message)? logError,
}) {
  final emit =
      logError ??
      (String title, Object? message) {
        Log.error(title, message ?? 'null');
      };
  FlutterError.onError = (details) {
    emit("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
}

Timer? installBootstrapStartupHooks({
  required bool enableWindowsHeartbeat,
  Timer? existingHeartbeatTimer,
  Duration heartbeatInterval = const Duration(seconds: 1),
  Future<void> Function()? sendHeartbeat,
  void Function(String title, Object? message)? logError,
}) {
  installFlutterErrorLogger(logError: logError);
  return existingHeartbeatTimer ??
      startWindowsHeartbeat(
        enabled: enableWindowsHeartbeat,
        interval: heartbeatInterval,
        sendHeartbeat: sendHeartbeat,
      );
}

class BootstrapController extends ChangeNotifier {
  BootstrapController({
    Duration startupInteractionProtectionWindow = const Duration(seconds: 6),
  }) : _startupInteractionProtectionWindow = startupInteractionProtectionWindow;

  BootstrapPhase phase = BootstrapPhase.idle;

  bool phaseAReady = false;
  bool phaseBReady = false;
  bool comicSourceReady = false;
  bool networkReady = false;
  bool homeInteractive = false;

  bool _started = false;
  final Stopwatch _stopwatch = Stopwatch();
  final Completer<void> _phaseBCompleter = Completer<void>();
  final Completer<void> _readyCompleter = Completer<void>();
  final Completer<void> _homeInteractiveCompleter = Completer<void>();

  Future<void>? _phaseBFuture;
  Future<void>? _phaseCFuture;
  Timer? _windowsHeartbeatTimer;
  final Duration _startupInteractionProtectionWindow;
  final Set<String> _scheduledStartupBackgroundTasks = {};
  DateTime? _lifecycleQuietUntil;

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    _prepareStartupHooks();
    _stopwatch.start();
    unawaited(
      _run().catchError((Object error, StackTrace stackTrace) {
        Log.error(
          "Bootstrap",
          "Bootstrap failed unexpectedly: $error\n$stackTrace",
        );
      }),
    );
  }

  Future<void> waitForPhaseB() async {
    await _phaseBCompleter.future;
  }

  @visibleForTesting
  void debugCompletePhaseBForTest() {
    if (!_phaseBCompleter.isCompleted) {
      _phaseBCompleter.complete();
    }
  }

  Future<void> waitForReady() async {
    await _readyCompleter.future;
  }

  Future<void> waitForHomeInteractive() async {
    await _homeInteractiveCompleter.future;
  }

  void markHomeInteractive() {
    if (homeInteractive) {
      return;
    }
    homeInteractive = true;
    if (!_homeInteractiveCompleter.isCompleted) {
      _homeInteractiveCompleter.complete();
    }
    logPerf('home interactive');
    notifyListeners();
  }

  void markLifecyclePaused() {
    _lifecycleQuietUntil = null;
  }

  void markLifecycleResumed({
    DateTime? now,
    Duration quietWindow = _kLifecycleResumeQuietWindow,
  }) {
    final currentTime = now ?? DateTime.now();
    _lifecycleQuietUntil = currentTime.add(quietWindow);
    logPerf('lifecycle resumed quiet window');
  }

  Duration get lifecycleResumeQuietRemaining {
    final quietUntil = _lifecycleQuietUntil;
    if (quietUntil == null) {
      return Duration.zero;
    }
    final remaining = quietUntil.difference(DateTime.now());
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  Future<void> waitForInteractionQuiet() async {
    while (true) {
      final remaining = lifecycleResumeQuietRemaining;
      if (remaining <= Duration.zero) {
        return;
      }
      await Future<void>.delayed(remaining);
    }
  }

  Future<void> _run() async {
    phase = BootstrapPhase.phaseA;
    notifyListeners();
    logPerf('bootstrap start');

    await App.init().wait();
    await BackupImportCoordinator(
      Directory(App.dataPath),
    ).recoverInterruptedImport();
    await appdata.init().wait();

    phaseAReady = true;
    phase = BootstrapPhase.phaseB;
    notifyListeners();
    logPerf('phaseA ready');

    _phaseBFuture = _runPhaseB();
    await _phaseBFuture;

    phaseBReady = true;
    if (!_phaseBCompleter.isCompleted) {
      _phaseBCompleter.complete();
    }
    phase = BootstrapPhase.phaseC;
    notifyListeners();
    logPerf('phaseB ready');

    _phaseCFuture = _runPhaseC();
    await _phaseCFuture;

    phase = BootstrapPhase.ready;
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
    notifyListeners();
    logPerf('bootstrap ready');
  }

  Future<void> _runPhaseB() async {
    await SingleInstanceCookieJar.createInstance();
    await Future.wait([
      App.history.init().wait(),
      App.favorites.init().wait(),
      App.local.init().wait(),
      AppTranslation.init().wait(),
      TagsTranslation.readData().wait(),
      guardBootstrapTask(OpenCC.init()),
    ]);
    CacheManager().setLimitSize(
      normalizeCacheSizeMb(appdata.settings['cacheSize']),
    );
  }

  Future<void> _runPhaseC() async {
    await JsEngine().init().wait();
    await ComicSourceManager().init().wait();
    comicSourceReady = true;
    notifyListeners();
    logPerf('comic source ready');
    _checkOldConfigs();

    try {
      await AppDio.ensureNetworkReady();
      networkReady = true;
      notifyListeners();
      logPerf('network ready');
    } catch (e, s) {
      Log.error("bootstrap", "$e\n$s");
    }

    await SAFTaskWorker().init().wait();
    _postBootstrapHooks();
  }

  void schedulePostFrameWork() {
    scheduleStartupBackgroundTask(
      'cache maintenance',
      const Duration(seconds: 10),
      () async {
        CacheManager().scheduleInitialMaintenance(Duration.zero);
      },
    );
    scheduleStartupBackgroundTask(
      'local downloaded state repair',
      const Duration(seconds: 15),
      () => App.local.repairAllDownloadedStateBatched(),
    );
    scheduleStartupBackgroundTask(
      'update checks',
      const Duration(seconds: 20),
      () async {
        await waitForReady();
        if (networkReady) {
          checkUpdates();
        }
      },
    );
  }

  void scheduleStartupBackgroundTask(
    String name,
    Duration delay,
    FutureOr<void> Function() action,
  ) {
    if (!_scheduledStartupBackgroundTasks.add(name)) {
      return;
    }
    logPerf('startup task scheduled $name');
    unawaited(() async {
      await waitForPhaseB();
      await waitForHomeInteractive();
      await Future.delayed(_startupInteractionProtectionWindow + delay);
      await waitForInteractionQuiet();
      logPerf('startup task start $name');
      try {
        await action();
      } catch (e, s) {
        Log.error('Bootstrap', 'Startup task "$name" failed: $e\n$s');
      } finally {
        logPerf('startup task complete $name');
      }
    }());
  }

  void _postBootstrapHooks() {
    if (App.isAndroid) {
      handleLinks();
      handleTextShare();
      unawaited(_setHighRefreshRate());
    }
  }

  void _prepareStartupHooks() {
    _windowsHeartbeatTimer = installBootstrapStartupHooks(
      enableWindowsHeartbeat: App.isWindows,
      existingHeartbeatTimer: _windowsHeartbeatTimer,
    );
  }

  Future<void> _setHighRefreshRate() async {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }

  void logPerf(String label) {
    PerfTrace.instant(
      label,
      component: 'Bootstrap',
      elapsed: _stopwatch.elapsed,
    );
  }
}

Timer? startWindowsHeartbeat({
  required bool enabled,
  Duration interval = const Duration(seconds: 1),
  Future<void> Function()? sendHeartbeat,
}) {
  if (!enabled) {
    return null;
  }
  final emitHeartbeat =
      sendHeartbeat ??
      () async {
        const methodChannel = MethodChannel('venera/method_channel');
        await methodChannel.invokeMethod("heartBeat");
      };
  return Timer.periodic(interval, (_) {
    unawaited(
      emitHeartbeat().catchError((Object e, StackTrace s) {
        Log.error("Heartbeat", "Failed to emit heartbeat: $e\n$s");
      }),
    );
  });
}

Future<void> _checkAppUpdates() async {
  var lastCheck = appdata.implicitData['lastCheckUpdate'] ?? 0;
  var now = DateTime.now().millisecondsSinceEpoch;
  if (now - lastCheck < 24 * 60 * 60 * 1000) {
    return;
  }
  appdata.implicitData['lastCheckUpdate'] = now;
  appdata.writeImplicitData();
  ComicSourcePage.checkComicSourceUpdate();
  if (shouldCheckUpdateOnStart(appdata.settings['checkUpdateOnStart'])) {
    await checkUpdateUi(false, true);
  }
}

void checkUpdates() {
  if (!AppDio.isNetworkReady) {
    Log.error(
      "Check Update",
      "Skipped automatic update checks because network is unavailable. "
              "${AppDio.networkUnavailableReason ?? ''}"
          .trim(),
    );
    return;
  }
  unawaited(
    _checkAppUpdates().catchError((Object e, StackTrace s) {
      Log.error("Check Update", "Automatic update checks failed: $e\n$s");
    }),
  );
  FollowUpdatesService.initChecker();
}

void _checkOldConfigs() {
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }

  if (appdata.settings['comicSourceListUrl'].toString().contains(
    "git.nyne.dev",
  )) {
    appdata.settings['comicSourceListUrl'] =
        "https://cdn.jsdelivr.net/gh/cyc20050130/venera-configs@main/index.json";
    appdata.saveDataInBackground();
  }
}
