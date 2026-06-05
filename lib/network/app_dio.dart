import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/proxy.dart';

import '../foundation/app.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';

export 'package:dio/dio.dart';

const Set<String> _ignoredPreventParallelHeaders = {
  'prevent-parallel',
  'cache-time',
  'date',
  'connection',
  'content-length',
  'transfer-encoding',
};

@visibleForTesting
String? buildPreventParallelRequestKey({
  required String method,
  required String path,
  Map<String, dynamic>? queryParameters,
  Map<String, dynamic>? headers,
  String baseUrl = '',
}) {
  if (method.toUpperCase() != 'GET') {
    return null;
  }
  final normalizedUri = _normalizePreventParallelUri(
    path: path,
    queryParameters: queryParameters,
    baseUrl: baseUrl,
  );
  if (normalizedUri == null) {
    return null;
  }
  final normalizedHeaders = _normalizePreventParallelHeaders(headers ?? {});
  final headerFingerprint = normalizedHeaders.entries
      .map(
        (entry) =>
            '${Uri.encodeComponent(entry.key)}='
            '${entry.value.map(Uri.encodeComponent).join(',')}',
      )
      .join('&');
  return 'GET $normalizedUri $headerFingerprint';
}

String? _normalizePreventParallelUri({
  required String path,
  Map<String, dynamic>? queryParameters,
  required String baseUrl,
}) {
  final Uri resolved;
  try {
    if (_hasMalformedPercentEncoding(path) ||
        (baseUrl.isNotEmpty && _hasMalformedPercentEncoding(baseUrl))) {
      return null;
    }
    final parsedPath = Uri.parse(path);
    resolved = parsedPath.hasScheme || baseUrl.isEmpty
        ? parsedPath
        : Uri.parse(baseUrl).resolve(path);
  } catch (_) {
    return null;
  }
  final normalizedQuery = SplayTreeMap<String, List<String>>();

  void addQueryValue(String key, Object? value) {
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty || value == null) {
      return;
    }
    final target = normalizedQuery.putIfAbsent(normalizedKey, () => <String>[]);
    if (value is Iterable && value is! String) {
      for (final item in value) {
        if (item != null) {
          final normalizedValue = item.toString().trim();
          if (normalizedValue.isNotEmpty) {
            target.add(normalizedValue);
          }
        }
      }
    } else {
      final normalizedValue = value.toString().trim();
      if (normalizedValue.isNotEmpty) {
        target.add(normalizedValue);
      }
    }
  }

  for (final entry in resolved.queryParametersAll.entries) {
    for (final value in entry.value) {
      addQueryValue(entry.key, value);
    }
  }
  queryParameters?.forEach(addQueryValue);

  final queryParts = <String>[];
  for (final entry in normalizedQuery.entries) {
    final values = entry.value..sort();
    if (values.isEmpty) {
      queryParts.add(Uri.encodeQueryComponent(entry.key));
    } else {
      for (final value in values) {
        queryParts.add(
          '${Uri.encodeQueryComponent(entry.key)}='
          '${Uri.encodeQueryComponent(value)}',
        );
      }
    }
  }

  final normalizedUri = resolved.replace(
    scheme: resolved.scheme.toLowerCase(),
    host: resolved.host.toLowerCase(),
    query: queryParts.isEmpty ? null : queryParts.join('&'),
  );
  return normalizedUri.toString();
}

bool _hasMalformedPercentEncoding(String value) {
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) != 0x25) {
      continue;
    }
    if (i + 2 >= value.length ||
        !_isHexCodeUnit(value.codeUnitAt(i + 1)) ||
        !_isHexCodeUnit(value.codeUnitAt(i + 2))) {
      return true;
    }
  }
  return false;
}

bool _isHexCodeUnit(int codeUnit) {
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x46) ||
      (codeUnit >= 0x61 && codeUnit <= 0x66);
}

Map<String, List<String>> _normalizePreventParallelHeaders(
  Map<String, dynamic> headers,
) {
  final result = SplayTreeMap<String, List<String>>();
  for (final entry in headers.entries) {
    final key = entry.key.toLowerCase().trim();
    if (key.isEmpty || _ignoredPreventParallelHeaders.contains(key)) {
      continue;
    }
    final values = _normalizePreventParallelHeaderValue(entry.value);
    if (values.isNotEmpty) {
      result[key] = values;
    }
  }
  return result;
}

List<String> _normalizePreventParallelHeaderValue(Object? value) {
  if (value == null) {
    return const [];
  }
  final values = <String>[];
  if (value is Iterable && value is! String) {
    for (final item in value) {
      final normalized = item?.toString().trim() ?? '';
      if (normalized.isNotEmpty) {
        values.add(normalized);
      }
    }
  } else {
    final normalized = value.toString().trim();
    if (normalized.isNotEmpty) {
      values.add(normalized);
    }
  }
  values.sort();
  return values;
}

class MyLogInterceptor implements Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    Log.error(
      "Network",
      "${err.requestOptions.method} ${err.requestOptions.path}\n$err\n${err.response?.data.toString()}",
    );
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
            message:
                "Invalid Status Code: $statusCode. "
                "${_getStatusCodeInfo(statusCode)}",
          );
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
          message:
              "Receive Timeout: "
              "This indicates that the server is too busy to respond",
        );
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
            message:
                "Connection terminated during handshake: "
                "This may be caused by the firewall blocking the connection "
                "or your requests are too frequent.",
          );
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
            message:
                "Connection reset by peer: "
                "The error is unrelated to app, please check your network.",
          );
        }
      default:
        {}
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    var headers = response.headers.map.map(
      (key, value) => MapEntry(
        key.toLowerCase(),
        value.length == 1 ? value.first : value.toString(),
      ),
    );
    headers.remove("cookie");
    String content;
    if (response.data is List<int>) {
      try {
        content = utf8.decode(response.data, allowMalformed: false);
      } catch (e) {
        content = "<Bytes>\nlength:${response.data.length}";
      }
    } else {
      content = response.data.toString();
    }
    Log.addLog(
      (response.statusCode != null && response.statusCode! < 400)
          ? LogLevel.info
          : LogLevel.error,
      "Network",
      "Response ${response.realUri.toString()} ${response.statusCode}\n"
          "headers:\n$headers\n$content",
    );
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    const String headerMask = "********";
    const String dataMask = "****** DATA_PROTECTED ******";
    Log.info(
      "Network",
      "${options.method} ${options.uri}\n"
          "headers:\n${options.extra.containsKey("maskHeadersInLog") ? options.headers.map((key, value) => MapEntry(key, options.extra["maskHeadersInLog"].contains(key) ? headerMask : value)) : options.headers}\n"
          "data:\n${options.extra["maskDataInLog"] == true ? dataMask : options.data}",
    );
    options.connectTimeout = const Duration(seconds: 15);
    options.receiveTimeout = const Duration(seconds: 15);
    options.sendTimeout = const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio with DioMixin {
  static bool _networkReady = false;
  static Object? _networkInitError;
  static Future<void>? _networkInitFuture;
  static Future<void> Function()? _networkInitializerForTest;

  static bool get isNetworkReady => _networkReady;

  static String? get networkUnavailableReason {
    final error = _networkInitError;
    return error?.toString();
  }

  static void markNetworkInitialized() {
    _networkReady = true;
    _networkInitError = null;
    _networkInitFuture = Future.value();
  }

  static void markNetworkInitializationFailed(Object error) {
    _networkReady = false;
    _networkInitError = error;
    _networkInitFuture = null;
  }

  @visibleForTesting
  static void debugResetNetworkState() {
    _networkReady = false;
    _networkInitError = null;
    _networkInitFuture = null;
    _networkInitializerForTest = null;
  }

  @visibleForTesting
  static void debugSetNetworkInitializer(Future<void> Function()? initializer) {
    _networkInitializerForTest = initializer;
    _networkInitFuture = null;
    _networkInitError = null;
    _networkReady = false;
  }

  static Future<void> ensureNetworkReady() async {
    if (_networkReady) {
      return;
    }

    if (_networkInitError != null && _networkInitFuture == null) {
      throw StateError(networkUnavailableReason ?? "Rhttp is not initialized.");
    }

    final future = _networkInitFuture ??= _initializeNetwork();
    try {
      await future;
    } catch (_) {
      // Normalize all initialization failures to a stable StateError below.
    }

    if (!_networkReady) {
      throw StateError(networkUnavailableReason ?? "Rhttp is not initialized.");
    }
  }

  static Future<void> _initializeNetwork() async {
    try {
      final initializer = _networkInitializerForTest ?? rhttp.Rhttp.init;
      await initializer();
      markNetworkInitialized();
    } catch (e) {
      _networkReady = false;
      _networkInitError = e;
      rethrow;
    }
  }

  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
    httpClientAdapter = RHttpAdapter();
    interceptors.add(_PreventParallelHeaderInterceptor());
    if (App.isInitialized) {
      final cookieJar = SingleInstanceCookieJar.instance;
      if (cookieJar != null) {
        interceptors.add(CookieManagerSql(cookieJar));
      } else {
        Log.warning("Network", "Cookie jar is unavailable; cookies disabled");
      }
      interceptors.add(NetworkCacheManager());
      interceptors.add(CloudflareInterceptor());
      interceptors.add(MyLogInterceptor());
    }
  }

  static final Set<String> _requests = {};

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    final effectiveHeaders = _effectivePreventParallelHeaders(
      this.options.headers,
      options?.headers,
    );
    final preventParallel = _hasPreventParallelHeader(effectiveHeaders);
    String? preventParallelKey;
    if (preventParallel) {
      preventParallelKey = buildPreventParallelRequestKey(
        method: options?.method ?? this.options.method,
        path: path,
        queryParameters: queryParameters,
        headers: effectiveHeaders,
        baseUrl: this.options.baseUrl,
      );
    }
    if (preventParallelKey != null) {
      while (_requests.contains(preventParallelKey)) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      _requests.add(preventParallelKey);
    }

    try {
      return await super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    } finally {
      if (preventParallelKey != null) {
        _requests.remove(preventParallelKey);
      }
    }
  }
}

Map<String, dynamic> _effectivePreventParallelHeaders(
  Map<String, dynamic> baseHeaders,
  Map<String, dynamic>? requestHeaders,
) {
  final result = <String, dynamic>{};

  void setHeader(String key, dynamic value) {
    final normalizedKey = key.toLowerCase();
    String? existingKey;
    for (final candidate in result.keys) {
      if (candidate.toLowerCase() == normalizedKey) {
        existingKey = candidate;
        break;
      }
    }
    if (existingKey != null) {
      result.remove(existingKey);
    }
    result[key] = value;
  }

  baseHeaders.forEach(setHeader);
  requestHeaders?.forEach(setHeader);
  return result;
}

bool _hasPreventParallelHeader(Map<String, dynamic>? headers) {
  if (headers == null) {
    return false;
  }
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'prevent-parallel') {
      return entry.value?.toString().toLowerCase() == 'true';
    }
  }
  return false;
}

@visibleForTesting
bool shouldEnableDnsOverrides(Object? value) {
  return normalizeBoolSetting(value, false);
}

void _removePreventParallelHeader(Map<String, dynamic>? headers) {
  if (headers == null) {
    return;
  }
  final keys = headers.keys
      .where((key) => key.toLowerCase() == 'prevent-parallel')
      .toList(growable: false);
  for (final key in keys) {
    headers.remove(key);
  }
}

class _PreventParallelHeaderInterceptor implements Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _removePreventParallelHeader(options.headers);
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.next(err);
  }
}

class RHttpAdapter implements HttpClientAdapter {
  Future<rhttp.ClientSettings> get settings async {
    var proxy = await getProxy();

    return rhttp.ClientSettings(
      proxySettings: proxy == null
          ? const rhttp.ProxySettings.noProxy()
          : rhttp.ProxySettings.proxy(proxy),
      redirectSettings: const rhttp.RedirectSettings.limited(5),
      timeoutSettings: const rhttp.TimeoutSettings(
        connectTimeout: Duration(seconds: 15),
        keepAliveTimeout: Duration(seconds: 60),
        keepAlivePing: Duration(seconds: 30),
      ),
      throwOnStatusCode: false,
      dnsSettings: rhttp.DnsSettings.static(overrides: _getOverrides()),
      tlsSettings: rhttp.TlsSettings(
        sni: appdata.settings['sni'] != false,
        verifyCertificates: appdata.settings['ignoreBadCertificate'] != true,
      ),
    );
  }

  static Map<String, List<String>> _getOverrides() {
    if (!shouldEnableDnsOverrides(appdata.settings['enableDnsOverrides'])) {
      return {};
    }
    var config = appdata.settings["dnsOverrides"];
    var result = <String, List<String>>{};
    if (config is Map) {
      for (var entry in config.entries) {
        if (entry.key is String && entry.value is String) {
          result[entry.key] = [entry.value];
        }
      }
    }
    return result;
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    try {
      await AppDio.ensureNetworkReady();
    } catch (e) {
      final reason = e.toString();
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        error: e,
        message:
            "Network is unavailable because the HTTP runtime failed to initialize. $reason",
      );
    }

    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = "venera/v${App.version}";
    }

    var res = await rhttp.Rhttp.request(
      method: rhttp.HttpMethod(options.method),
      url: options.uri.toString(),
      settings: await settings,
      expectBody: rhttp.HttpExpectBody.stream,
      body: requestStream == null ? null : rhttp.HttpBody.stream(requestStream),
      headers: rhttp.HttpHeaders.rawMap(
        Map.fromEntries(
          options.headers.entries.map(
            (e) => MapEntry(e.key, e.value.toString().trim()),
          ),
        ),
      ),
    );
    if (res is! rhttp.HttpStreamResponse) {
      throw Exception("Invalid response type: ${res.runtimeType}");
    }
    var headers = <String, List<String>>{};
    for (var entry in res.headers) {
      var key = entry.$1.toLowerCase();
      headers[key] ??= [];
      headers[key]!.add(entry.$2);
    }
    return ResponseBody(
      res.body,
      res.statusCode,
      statusMessage: _getStatusMessage(res.statusCode),
      isRedirect: false,
      headers: headers,
    );
  }

  static String _getStatusMessage(int statusCode) {
    return switch (statusCode) {
      200 => "OK",
      201 => "Created",
      202 => "Accepted",
      204 => "No Content",
      206 => "Partial Content",
      301 => "Moved Permanently",
      302 => "Found",
      400 => "Invalid Status Code 400: The Request is invalid.",
      401 => "Invalid Status Code 401: The Request is unauthorized.",
      403 =>
        "Invalid Status Code 403: No permission to access the resource. Check your account or network.",
      404 => "Invalid Status Code 404: Not found.",
      429 =>
        "Invalid Status Code 429: Too many requests. Please try again later.",
      _ => "Invalid Status Code $statusCode",
    };
  }
}
