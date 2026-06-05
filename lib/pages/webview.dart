import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';
import 'dart:io' as io;

export 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show WebUri, URLRequest;

@visibleForTesting
String? normalizeWebviewUserAgent(Object? value) {
  if (value is! String) {
    return null;
  }
  if (value.length >= 2 &&
      ((value.startsWith("'") && value.endsWith("'")) ||
          (value.startsWith('"') && value.endsWith('"')))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

@visibleForTesting
Map<String, String?>? parseDesktopWebviewDocumentMessage(String message) {
  if (message.trim().isEmpty) {
    return null;
  }
  try {
    final json = jsonDecode(message);
    if (json is! Map || json["id"] != "document_created") {
      return null;
    }
    final data = json["data"];
    if (data is! Map) {
      return null;
    }
    final title = data["title"];
    if (title is! String) {
      return null;
    }
    return {"title": title, "ua": normalizeWebviewUserAgent(data["ua"])};
  } catch (_) {
    return null;
  }
}

@visibleForTesting
bool shouldHandleDesktopWebviewClose({
  required int callbackSession,
  required int currentSession,
  required bool isCurrentWebview,
  required int? closingSession,
  required bool hasActiveWebview,
}) {
  if (isCurrentWebview) {
    return true;
  }
  return closingSession == callbackSession &&
      currentSession == callbackSession &&
      !hasActiveWebview;
}

extension WebviewExtension on InAppWebViewController {
  Future<List<io.Cookie>?> getCookies(String url) async {
    if (url.isEmpty) {
      return [];
    }
    if (url[url.length - 1] == '/') {
      url = url.substring(0, url.length - 1);
    }
    CookieManager cookieManager = CookieManager.instance(
      webViewEnvironment: AppWebview.webViewEnvironment,
    );
    final List<Cookie> cookies;
    try {
      cookies = await cookieManager.getCookies(
        url: WebUri(url),
        webViewController: this,
      );
    } catch (e, s) {
      Log.error("Webview", "Failed to read cookies: $e", s);
      return [];
    }
    var res = <io.Cookie>[];
    for (var cookie in cookies) {
      var c = io.Cookie(cookie.name, cookie.value);
      c.domain = cookie.domain;
      res.add(c);
    }
    return res;
  }

  Future<String?> getUA() async {
    var res = await evaluateJavascript(source: "navigator.userAgent");
    return normalizeWebviewUserAgent(res);
  }
}

class AppWebview extends StatefulWidget {
  const AppWebview({
    required this.initialUrl,
    this.onTitleChange,
    this.onNavigation,
    this.singlePage = false,
    this.onStarted,
    this.onLoadStop,
    super.key,
  });

  final String initialUrl;

  final void Function(String title, InAppWebViewController controller)?
  onTitleChange;

  final bool Function(String url, InAppWebViewController controller)?
  onNavigation;

  final void Function(InAppWebViewController controller)? onStarted;

  final void Function(InAppWebViewController controller)? onLoadStop;

  final bool singlePage;

  static WebViewEnvironment? webViewEnvironment;

  @override
  State<AppWebview> createState() => _AppWebviewState();
}

class _AppWebviewState extends State<AppWebview> {
  InAppWebViewController? controller;

  String title = "Webview";

  double _progress = 0;

  late var future = _createWebviewEnvironment();

  Future<bool> _createWebviewEnvironment() async {
    var proxy = appdata.settings['proxy'].toString();
    if (proxy != "system" && proxy != "direct") {
      var proxyAvailable = await WebViewFeature.isFeatureSupported(
        WebViewFeature.PROXY_OVERRIDE,
      );
      if (proxyAvailable) {
        ProxyController proxyController = ProxyController.instance();
        await proxyController.clearProxyOverride();
        if (!proxy.contains("://")) {
          proxy = "http://$proxy";
        }
        await proxyController.setProxyOverride(
          settings: ProxySettings(proxyRules: [ProxyRule(url: proxy)]),
        );
      }
    }
    if (!App.isWindows) {
      return true;
    }
    AppWebview.webViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: "${App.dataPath}\\webview",
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final actions = [
      Tooltip(
        message: "More",
        child: IconButton(
          icon: const Icon(Icons.more_horiz),
          onPressed: () {
            showMenuX(context, Offset(context.width, context.padding.top), [
              MenuEntry(
                icon: Icons.open_in_browser,
                text: "Open in browser".tl,
                onClick: () async {
                  final url = (await controller?.getUrl())?.toString();
                  if (url == null || url.isEmpty) {
                    return;
                  }
                  await launchUrlString(url);
                },
              ),
              MenuEntry(
                icon: Icons.copy,
                text: "Copy link".tl,
                onClick: () async {
                  final url = (await controller?.getUrl())?.toString();
                  if (url == null || url.isEmpty) {
                    return;
                  }
                  await Clipboard.setData(ClipboardData(text: url));
                },
              ),
              MenuEntry(
                icon: Icons.refresh,
                text: "Reload".tl,
                onClick: () => controller?.reload(),
              ),
            ]);
          },
        ),
      ),
    ];

    Widget body = FutureBuilder(
      future: future,
      builder: (context, e) {
        if (e.error != null) {
          return Center(child: Text("Error: ${e.error}"));
        }
        if (!e.hasData) {
          return const SizedBox();
        }
        return createWebviewWithEnvironment(AppWebview.webViewEnvironment);
      },
    );

    body = Stack(
      children: [
        Positioned.fill(child: body),
        if (_progress < 1.0)
          const Positioned.fill(
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );

    return Scaffold(
      appBar: Appbar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: actions,
      ),
      body: body,
    );
  }

  Widget createWebviewWithEnvironment(WebViewEnvironment? e) {
    return InAppWebView(
      webViewEnvironment: e,
      initialSettings: InAppWebViewSettings(isInspectable: true),
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
      onTitleChanged: (c, t) {
        final nextTitle = t ?? "Webview";
        if (mounted) {
          setState(() {
            title = nextTitle;
          });
        }
        widget.onTitleChange?.call(nextTitle, c);
      },
      shouldOverrideUrlLoading: (c, r) async {
        var res =
            widget.onNavigation?.call(r.request.url?.toString() ?? "", c) ??
            false;
        if (res) {
          return NavigationActionPolicy.CANCEL;
        } else {
          return NavigationActionPolicy.ALLOW;
        }
      },
      onWebViewCreated: (c) {
        controller = c;
        widget.onStarted?.call(c);
      },
      onLoadStop: (c, r) {
        widget.onLoadStop?.call(c);
      },
      onProgressChanged: (c, p) {
        if (mounted) {
          setState(() {
            _progress = p / 100;
          });
        }
      },
    );
  }
}

class DesktopWebview {
  static Future<bool> isAvailable() => WebviewWindow.isWebviewAvailable();

  final String initialUrl;

  final void Function(String title, DesktopWebview controller)? onTitleChange;

  final void Function(String url, DesktopWebview webview)? onNavigation;

  final void Function(DesktopWebview controller)? onStarted;

  final void Function()? onClose;

  DesktopWebview({
    required this.initialUrl,
    this.onTitleChange,
    this.onNavigation,
    this.onStarted,
    this.onClose,
  });

  Webview? _webview;

  int _session = 0;

  int? _closingSession;

  String? _ua;

  String? title;

  void onMessage(String message) {
    final parsed = parseDesktopWebviewDocumentMessage(message);
    if (parsed == null) {
      return;
    }
    try {
      title = parsed["title"];
      _ua = parsed["ua"];
      onTitleChange?.call(title!, this);
    } catch (e, s) {
      Log.error("Webview", e, s);
    }
  }

  String? get userAgent => _ua;

  Timer? timer;

  bool _isPollingDocument = false;

  void _runTimer() {
    timer ??= Timer.periodic(const Duration(seconds: 2), (t) async {
      if (_isPollingDocument) {
        return;
      }
      const js = '''
        function collect() {
          if(document.readyState === 'loading') {
            return '';
          }
          let data = {
            id: "document_created",
            data: {
              title: document.title,
              url: location.href,
              ua: navigator.userAgent
            }
          };
          return data;
        }
        collect();
      ''';
      final webview = _webview;
      if (webview == null) {
        t.cancel();
        if (timer == t) {
          timer = null;
        }
        return;
      }
      _isPollingDocument = true;
      try {
        final message = await webview.evaluateJavaScript(js);
        if (_webview == webview) {
          onMessage(message ?? '');
        }
      } catch (e, s) {
        if (_webview == webview) {
          Log.error("Webview", e, s);
        }
      } finally {
        _isPollingDocument = false;
      }
    });
  }

  void open() async {
    close();
    final session = ++_session;
    try {
      final webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          useWindowPositionAndSize: true,
          userDataFolderWindows: "${App.dataPath}\\webview",
          title: "webview",
          proxy: await getProxy(),
        ),
      );
      if (session != _session) {
        webview.close();
        return;
      }
      _webview = webview;
      webview.addOnWebMessageReceivedCallback(onMessage);
      webview.setOnNavigation((s) {
        if (s.length >= 2 &&
            ((s.startsWith('"') && s.endsWith('"')) ||
                (s.startsWith("'") && s.endsWith("'")))) {
          s = s.substring(1, s.length - 1);
        }
        return onNavigation?.call(s, this);
      });
      webview.launch(initialUrl, triggerOnUrlRequestEvent: false);
      _runTimer();
      final openedWebview = webview;
      openedWebview.onClose.then((value) {
        final isCurrentWebview = _webview == openedWebview;
        if (!shouldHandleDesktopWebviewClose(
          callbackSession: session,
          currentSession: _session,
          isCurrentWebview: isCurrentWebview,
          closingSession: _closingSession,
          hasActiveWebview: _webview != null,
        )) {
          return;
        }
        if (isCurrentWebview) {
          _webview = null;
        }
        if (_closingSession == session) {
          _closingSession = null;
        }
        _cancelTimer();
        onClose?.call();
      });
      Future.delayed(const Duration(milliseconds: 200), () {
        if (_webview == openedWebview) {
          onStarted?.call(this);
        }
      });
    } catch (e, s) {
      Log.error("Webview", "Failed to open desktop webview: $e", s);
      close();
      onClose?.call();
    }
  }

  Future<String?> evaluateJavascript(String source) {
    return _webview?.evaluateJavaScript(source) ?? Future.value(null);
  }

  Future<Map<String, String>> getCookies(String url) async {
    final webview = _webview;
    if (webview == null) return {};
    var allCookies = await webview.getAllCookies();
    var res = <String, String>{};
    for (var c in allCookies) {
      if (_cookieMatch(url, c.domain)) {
        res[_removeCode0(c.name)] = _removeCode0(c.value);
      }
    }
    return res;
  }

  String _removeCode0(String s) {
    var codeUints = List<int>.from(s.codeUnits);
    codeUints.removeWhere((e) => e == 0);
    return String.fromCharCodes(codeUints);
  }

  bool _cookieMatch(String url, String domain) {
    domain = _removeCode0(domain);
    var host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) {
      return false;
    }
    var acceptedHost = _getAcceptedDomains(host);
    return acceptedHost.contains(domain.removeAllBlank);
  }

  List<String> _getAcceptedDomains(String host) {
    var acceptedDomains = <String>[host];
    var hostParts = host.split(".");
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add(".${hostParts.sublist(i).join(".")}");
    }
    return acceptedDomains;
  }

  void close() {
    final webview = _webview;
    _webview = null;
    if (webview != null) {
      _closingSession = _session;
    }
    _cancelTimer();
    webview?.close();
  }

  void _cancelTimer() {
    timer?.cancel();
    timer = null;
  }
}
