import 'dart:async';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:venera/foundation/bootstrap.dart';
import 'package:venera/design_system/app_design_system.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/overlay_entry.dart';
import 'package:window_manager/window_manager.dart';
import 'components/components.dart';
import 'components/window_frame.dart';
import 'foundation/app.dart';
import 'foundation/appdata.dart';
import 'headless.dart';

const Duration _lifecycleDownloadFlushThrottle = Duration(milliseconds: 700);
const Duration _lifecycleAuthPromptThrottle = Duration(seconds: 2);

abstract final class AppRoutePath {
  static const bootstrap = '/bootstrap';
  static const unlock = '/unlock';
  static const home = '/app';
}

@visibleForTesting
String? resolveRootRouteRedirect({
  required bool phaseAReady,
  required bool authorizationRequired,
  required bool startupAuthorized,
  required String currentLocation,
}) {
  final target = !phaseAReady
      ? AppRoutePath.bootstrap
      : authorizationRequired && !startupAuthorized
      ? AppRoutePath.unlock
      : AppRoutePath.home;
  return currentLocation == target ? null : target;
}

@visibleForTesting
bool shouldRequireAuthorization(Object? value) {
  return normalizeBoolSetting(value, false);
}

@visibleForTesting
bool shouldFlushDownloadsForLifecycleState({
  required AppLifecycleState state,
  required bool appInitialized,
  required bool phaseAReady,
  required DateTime now,
  required DateTime? lastFlushAt,
  Duration throttle = _lifecycleDownloadFlushThrottle,
}) {
  final isLeavingForeground =
      state == AppLifecycleState.inactive ||
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;
  if (!isLeavingForeground || !appInitialized || !phaseAReady) {
    return false;
  }
  if (lastFlushAt == null) {
    return true;
  }
  return now.difference(lastFlushAt) >= throttle;
}

@visibleForTesting
bool shouldShowLifecyclePrivacyOverlay({
  required AppLifecycleState state,
  required bool isMobile,
  required bool authorizationRequired,
  required bool hasOverlay,
}) {
  return isMobile &&
      authorizationRequired &&
      state == AppLifecycleState.inactive &&
      !hasOverlay;
}

@visibleForTesting
bool shouldRemoveLifecyclePrivacyOverlay({
  required AppLifecycleState state,
  required bool hasOverlay,
}) {
  return state == AppLifecycleState.resumed && hasOverlay;
}

@visibleForTesting
bool shouldPushLifecycleAuthPage({
  required AppLifecycleState state,
  required bool isMobile,
  required bool authorizationRequired,
  required bool isAuthPageActive,
  required bool isSelectingFiles,
  required DateTime now,
  required DateTime? lastAuthPromptAt,
  Duration throttle = _lifecycleAuthPromptThrottle,
}) {
  if (!isMobile ||
      !authorizationRequired ||
      state != AppLifecycleState.hidden ||
      isAuthPageActive ||
      isSelectingFiles) {
    return false;
  }
  if (lastAuthPromptAt == null) {
    return true;
  }
  return now.difference(lastAuthPromptAt) >= throttle;
}

void main(List<String> args) {
  if (args.contains('--headless')) {
    runHeadlessMode(args);
    return;
  }
  if (runWebViewTitleBarWidget(args)) return;
  overrideIO(() {
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        runApp(const ProviderScope(child: MyApp()));
        bootstrapController.start();
        if (App.isDesktop) {
          await windowManager.ensureInitialized();
          windowManager.waitUntilReadyToShow().then((_) async {
            await windowManager.setTitleBarStyle(
              TitleBarStyle.hidden,
              windowButtonVisibility: App.isMacOS,
            );
            if (App.isLinux) {
              await windowManager.setBackgroundColor(Colors.transparent);
            }
            await windowManager.setMinimumSize(const Size(500, 600));
            var placement = await WindowPlacement.loadFromFile();
            if (App.isLinux) {
              await windowManager.show();
              await placement.applyToWindow();
            } else {
              await placement.applyToWindow();
              await windowManager.show();
            }

            WindowPlacement.loop();
          });
        }
      },
      (error, stack) {
        Log.error("Unhandled Exception", error, stack);
      },
    );
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late final VoidCallback _forceRebuildCallback;
  late final GoRouter _router;
  bool _startupAuthorized = false;

  @override
  void initState() {
    super.initState();
    _router = GoRouter(
      navigatorKey: App.rootNavigatorKey,
      initialLocation: AppRoutePath.bootstrap,
      refreshListenable: Listenable.merge([
        bootstrapController,
        appdata.settings,
      ]),
      redirect: (context, state) => resolveRootRouteRedirect(
        phaseAReady: bootstrapController.phaseAReady,
        authorizationRequired: shouldRequireAuthorization(
          appdata.settings['authorizationRequired'],
        ),
        startupAuthorized: _startupAuthorized,
        currentLocation: state.uri.path,
      ),
      routes: [
        GoRoute(
          path: AppRoutePath.bootstrap,
          builder: (context, state) => const _BootstrapPage(),
        ),
        GoRoute(
          path: AppRoutePath.unlock,
          builder: (context, state) => AuthPage(
            onSuccessfulAuth: () {
              _startupAuthorized = true;
              _router.go(AppRoutePath.home);
            },
          ),
        ),
        GoRoute(
          path: AppRoutePath.home,
          builder: (context, state) => const MainPage(),
        ),
      ],
    );
    _forceRebuildCallback = forceRebuild;
    App.registerForceRebuild(_forceRebuildCallback);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      logBootstrapEvent('first Flutter frame');
      bootstrapController.schedulePostFrameWork();
    });
  }

  bool isAuthPageActive = false;

  OverlayEntry? hideContentOverlay;
  DateTime? _lastDownloadFlushAt;
  DateTime? _lastAuthPromptAt;

  @override
  void dispose() {
    App.unregisterForceRebuild(_forceRebuildCallback);
    WidgetsBinding.instance.removeObserver(this);
    final overlay = hideContentOverlay;
    hideContentOverlay = null;
    if (overlay != null) {
      removeAndDisposeOverlayEntry(overlay);
    }
    _router.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final now = DateTime.now();
    if (state == AppLifecycleState.resumed) {
      bootstrapController.markLifecycleResumed(now: now);
      ImageDownloader.markReaderLifecycleResumed(now: now);
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      bootstrapController.markLifecyclePaused();
      ImageDownloader.markReaderLifecyclePaused();
    }
    if (shouldFlushDownloadsForLifecycleState(
      state: state,
      appInitialized: App.isInitialized,
      phaseAReady: bootstrapController.phaseAReady,
      now: now,
      lastFlushAt: _lastDownloadFlushAt,
    )) {
      _lastDownloadFlushAt = now;
      App.local.flushCurrentDownloadingTasksInBackground(
        reason: 'lifecycle $state',
      );
    }
    final authorizationRequired = shouldRequireAuthorization(
      appdata.settings['authorizationRequired'],
    );
    if (!App.isMobile || !authorizationRequired) {
      return;
    }
    final rootContext = App.rootNavigatorKey.currentContext;
    if (shouldShowLifecyclePrivacyOverlay(
      state: state,
      isMobile: App.isMobile,
      authorizationRequired: authorizationRequired,
      hasOverlay: hideContentOverlay != null,
    )) {
      if (rootContext == null || !rootContext.mounted) {
        super.didChangeAppLifecycleState(state);
        return;
      }
      final overlayColor = rootContext.colorScheme.surface;
      hideContentOverlay = OverlayEntry(
        builder: (context) {
          return Positioned.fill(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: overlayColor,
            ),
          );
        },
      );
      Overlay.of(rootContext).insert(hideContentOverlay!);
    } else if (shouldRemoveLifecyclePrivacyOverlay(
      state: state,
      hasOverlay: hideContentOverlay != null,
    )) {
      final overlay = hideContentOverlay!;
      hideContentOverlay = null;
      removeAndDisposeOverlayEntry(overlay);
    }
    if (shouldPushLifecycleAuthPage(
      state: state,
      isMobile: App.isMobile,
      authorizationRequired: authorizationRequired,
      isAuthPageActive: isAuthPageActive,
      isSelectingFiles: IO.isSelectingFiles,
      now: now,
      lastAuthPromptAt: _lastAuthPromptAt,
    )) {
      final currentRootContext = App.rootNavigatorKey.currentContext;
      if (currentRootContext == null || !currentRootContext.mounted) {
        super.didChangeAppLifecycleState(state);
        return;
      }
      isAuthPageActive = true;
      _lastAuthPromptAt = now;
      final authFuture = currentRootContext.to(
        () => AuthPage(onSuccessfulAuth: _closeAuthPage),
      );
      unawaited(
        authFuture
            .whenComplete(() {
              isAuthPageActive = false;
            })
            .catchError((Object error, StackTrace stackTrace) {
              Log.error(
                "Lifecycle",
                "Lifecycle auth prompt failed: $error\n$stackTrace",
              );
            }),
      );
    }
    super.didChangeAppLifecycleState(state);
  }

  void _closeAuthPage() {
    final rootContext = App.rootNavigatorKey.currentContext;
    if (rootContext != null && rootContext.mounted) {
      Navigator.of(rootContext).maybePop();
    }
    isAuthPageActive = false;
  }

  void forceRebuild() {
    if (!mounted) {
      return;
    }
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
  }

  Color translateColorSetting() {
    return switch (appdata.settings['color']) {
      'red' => Colors.red,
      'pink' => Colors.pink,
      'purple' => Colors.purple,
      'green' => Colors.green,
      'orange' => Colors.orange,
      'blue' => Colors.blue,
      'yellow' => Colors.yellow,
      'cyan' => Colors.cyan,
      _ => Colors.blue,
    };
  }

  ThemeData getTheme(
    Color primary,
    Color? secondary,
    Color? tertiary,
    Brightness brightness,
  ) {
    String? font;
    List<String>? fallback;
    if (App.isLinux || App.isWindows) {
      font = 'Noto Sans CJK';
      fallback = [
        'Segoe UI',
        'Noto Sans SC',
        'Noto Sans TC',
        'Noto Sans',
        'Microsoft YaHei',
        'PingFang SC',
        'Arial',
        'sans-serif',
      ];
    }
    return AppTheme.build(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
      brightness: brightness,
      fontFamily: font,
      fontFamilyFallback: fallback,
    );
  }

  @override
  Widget build(BuildContext context) {
    final appBootstrapListenable = Listenable.merge([
      bootstrapController,
      appdata.settings,
    ]);
    return ListenableBuilder(
      listenable: appBootstrapListenable,
      builder: (context, _) {
        return DynamicColorBuilder(
          builder: (light, dark) {
            Color? primary, secondary, tertiary;
            if (appdata.settings['color'] != 'system' ||
                light == null ||
                dark == null) {
              primary = translateColorSetting();
            } else {
              primary = light.primary;
              secondary = light.secondary;
              tertiary = light.tertiary;
            }
            if (!bootstrapController.phaseAReady) {
              return MaterialApp.router(
                title: "venera",
                routerConfig: _router,
                debugShowCheckedModeBanner: false,
                theme: getTheme(primary, secondary, tertiary, Brightness.light),
                darkTheme: getTheme(
                  primary,
                  secondary,
                  tertiary,
                  Brightness.dark,
                ),
                themeMode: switch (appdata.settings['theme_mode']) {
                  'light' => ThemeMode.light,
                  'dark' => ThemeMode.dark,
                  _ => ThemeMode.system,
                },
                color: Colors.transparent,
                localizationsDelegates: [
                  GlobalMaterialLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                locale: () {
                  var lang = appdata.settings['language'];
                  if (lang == 'system') {
                    return null;
                  }
                  return switch (lang) {
                    'zh-CN' => const Locale('zh', 'CN'),
                    'zh-TW' => const Locale('zh', 'TW'),
                    'en-US' => const Locale('en'),
                    _ => null,
                  };
                }(),
                supportedLocales: const [
                  Locale('zh', 'CN'),
                  Locale('zh', 'TW'),
                  Locale('en'),
                ],
                builder: (context, widget) {
                  ErrorWidget.builder = (details) {
                    Log.error(
                      "Unhandled Exception",
                      "${details.exception}\n${details.stack}",
                    );
                    return Material(
                      child: Center(child: Text(details.exception.toString())),
                    );
                  };
                  if (widget != null) {
                    var isPaddingCheckError =
                        MediaQuery.of(context).viewPadding.top <= 0 ||
                        MediaQuery.of(context).viewPadding.top > 200;

                    if (isPaddingCheckError && Platform.isAndroid) {
                      widget = MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          viewPadding: const EdgeInsets.only(
                            top: 15,
                            bottom: 15,
                          ),
                          padding: const EdgeInsets.only(top: 15, bottom: 15),
                        ),
                        child: widget,
                      );
                    }

                    widget = OverlayWidget(widget);
                    if (App.isDesktop) {
                      widget = Shortcuts(
                        shortcuts: {
                          LogicalKeySet(LogicalKeyboardKey.escape):
                              VoidCallbackIntent(App.pop),
                        },
                        child: MouseBackDetector(
                          onTapDown: App.pop,
                          child: WindowFrame(widget),
                        ),
                      );
                    }
                    return _SystemUiProvider(
                      Material(
                        color: App.isLinux ? Colors.transparent : null,
                        child: widget,
                      ),
                    );
                  }
                  throw ('widget is null');
                },
              );
            }
            return MaterialApp.router(
              title: "venera",
              routerConfig: _router,
              debugShowCheckedModeBanner: false,
              theme: getTheme(primary, secondary, tertiary, Brightness.light),
              darkTheme: getTheme(
                primary,
                secondary,
                tertiary,
                Brightness.dark,
              ),
              themeMode: switch (appdata.settings['theme_mode']) {
                'light' => ThemeMode.light,
                'dark' => ThemeMode.dark,
                _ => ThemeMode.system,
              },
              color: Colors.transparent,
              localizationsDelegates: [
                GlobalMaterialLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              locale: () {
                var lang = appdata.settings['language'];
                if (lang == 'system') {
                  return null;
                }
                return switch (lang) {
                  'zh-CN' => const Locale('zh', 'CN'),
                  'zh-TW' => const Locale('zh', 'TW'),
                  'en-US' => const Locale('en'),
                  _ => null,
                };
              }(),
              supportedLocales: const [
                Locale('zh', 'CN'),
                Locale('zh', 'TW'),
                Locale('en'),
              ],
              builder: (context, widget) {
                ErrorWidget.builder = (details) {
                  Log.error(
                    "Unhandled Exception",
                    "${details.exception}\n${details.stack}",
                  );
                  return Material(
                    child: Center(child: Text(details.exception.toString())),
                  );
                };
                if (widget != null) {
                  /// 如果无法检测到状态栏高度设定指定高度
                  /// https://github.com/flutter/flutter/issues/161086
                  var isPaddingCheckError =
                      MediaQuery.of(context).viewPadding.top <= 0 ||
                      MediaQuery.of(context).viewPadding.top > 200;

                  if (isPaddingCheckError && Platform.isAndroid) {
                    widget = MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        viewPadding: const EdgeInsets.only(top: 15, bottom: 15),
                        padding: const EdgeInsets.only(top: 15, bottom: 15),
                      ),
                      child: widget,
                    );
                  }

                  widget = OverlayWidget(widget);
                  if (App.isDesktop) {
                    widget = Shortcuts(
                      shortcuts: {
                        LogicalKeySet(LogicalKeyboardKey.escape):
                            VoidCallbackIntent(App.pop),
                      },
                      child: MouseBackDetector(
                        onTapDown: App.pop,
                        child: WindowFrame(widget),
                      ),
                    );
                  }
                  return _SystemUiProvider(
                    Material(
                      color: App.isLinux ? Colors.transparent : null,
                      child: widget,
                    ),
                  );
                }
                throw ('widget is null');
              },
            );
          },
        );
      },
    );
  }
}

class _BootstrapPage extends StatelessWidget {
  const _BootstrapPage();

  String _phaseText(BootstrapPhase phase) {
    final locale = PlatformDispatcher.instance.locale;
    final isZh = locale.languageCode == 'zh';
    if (isZh) {
      return switch (phase) {
        BootstrapPhase.idle => '正在启动',
        BootstrapPhase.phaseA => '正在准备应用',
        BootstrapPhase.phaseB => '正在加载本地数据',
        BootstrapPhase.phaseC => '正在加载漫画源',
        BootstrapPhase.ready => '准备完成',
      };
    }
    return switch (phase) {
      BootstrapPhase.idle => 'Starting',
      BootstrapPhase.phaseA => 'Preparing app',
      BootstrapPhase.phaseB => 'Loading local data',
      BootstrapPhase.phaseC => 'Loading comic sources',
      BootstrapPhase.ready => 'Ready',
    };
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: ListenableBuilder(
        listenable: bootstrapController,
        builder: (context, _) {
          final phaseText = _phaseText(bootstrapController.phase);
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(
                      Icons.auto_stories_rounded,
                      size: 44,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text("venera", style: ts.s20),
                  const SizedBox(height: 12),
                  Text(
                    phaseText,
                    style: ts.s14.copyWith(color: colorScheme.outline),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SystemUiProvider extends StatelessWidget {
  const _SystemUiProvider(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var brightness = Theme.of(context).brightness;
    SystemUiOverlayStyle systemUiStyle;
    if (brightness == Brightness.light) {
      systemUiStyle = SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      );
    } else {
      systemUiStyle = SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: child,
    );
  }
}
