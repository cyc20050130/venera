import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

const int _maxNetworkCacheSize = 10 * 1024 * 1024;

const Set<String> _ignoredNetworkCacheHeaders = {
  'cache-time',
  'prevent-parallel',
  'date',
  'x-varnish',
  'cf-ray',
  'connection',
  'vary',
  'content-encoding',
  'report-to',
  'server-timing',
  'set-cookie',
  'cf-cache-status',
  'cf-request-id',
  'age',
  'alt-svc',
};

typedef NetworkCacheValidationFetcher =
    Future<Response<dynamic>> Function(RequestOptions options);

@visibleForTesting
bool shouldContinueRequestAfterCacheValidationError({required String method}) {
  return method.toUpperCase() == 'GET';
}

@visibleForTesting
String normalizeNetworkCacheUri(Uri uri) {
  final normalizedQuery = _normalizeQuery(uri);
  final normalized = uri.replace(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    query: normalizedQuery.isEmpty ? null : normalizedQuery,
  );
  return normalized.toString();
}

@visibleForTesting
Map<String, List<String>> normalizeNetworkCacheHeaders(
  Map<String, dynamic> headers,
) {
  final result = SplayTreeMap<String, List<String>>();
  for (final entry in headers.entries) {
    final key = entry.key.toLowerCase().trim();
    if (key.isEmpty || _ignoredNetworkCacheHeaders.contains(key)) {
      continue;
    }
    final values = _normalizeHeaderValue(entry.value);
    if (values.isEmpty) {
      continue;
    }
    result[key] = values;
  }
  return Map.unmodifiable(result);
}

@visibleForTesting
String buildNetworkCacheKey({
  required String method,
  required Uri uri,
  required Map<String, dynamic> headers,
}) {
  final normalizedHeaders = normalizeNetworkCacheHeaders(headers);
  final headerFingerprint = normalizedHeaders.entries
      .map(
        (entry) =>
            '${Uri.encodeComponent(entry.key)}='
            '${entry.value.map(Uri.encodeComponent).join(',')}',
      )
      .join('&');
  return '${method.toUpperCase()} ${normalizeNetworkCacheUri(uri)} '
      '$headerFingerprint';
}

@visibleForTesting
bool shouldStoreNetworkCacheEntrySize(
  int? size, {
  int maxSize = _maxNetworkCacheSize,
}) {
  return size != null && size > 0 && size < 1024 * 1024 && size <= maxSize;
}

@visibleForTesting
int? calculateNetworkCacheObjectSize(Object? data) {
  return NetworkCacheManager._calculateSize(data);
}

@visibleForTesting
String? networkCacheTimeHeaderValue(Map<String, dynamic> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase().trim() != 'cache-time') {
      continue;
    }
    final values = _normalizeHeaderValue(entry.value);
    if (values.isEmpty) {
      return null;
    }
    return values.first.toLowerCase();
  }
  return null;
}

@visibleForTesting
void removeNetworkCacheTimeHeader(Map<String, dynamic> headers) {
  final keys = headers.keys
      .where((key) => key.toLowerCase().trim() == 'cache-time')
      .toList(growable: false);
  for (final key in keys) {
    headers.remove(key);
  }
}

String _normalizeQuery(Uri uri) {
  if (!uri.hasQuery) {
    return '';
  }
  final queryParameters = uri.queryParametersAll;
  if (queryParameters.isEmpty) {
    return uri.query;
  }
  final keys = queryParameters.keys.toList()..sort();
  final parts = <String>[];
  for (final key in keys) {
    final encodedKey = Uri.encodeQueryComponent(key);
    final values = queryParameters[key]!;
    if (values.isEmpty) {
      parts.add(encodedKey);
      continue;
    }
    for (final value in values) {
      parts.add('$encodedKey=${Uri.encodeQueryComponent(value)}');
    }
  }
  return parts.join('&');
}

List<String> _normalizeHeaderValue(Object? value) {
  if (value == null) {
    return const [];
  }
  if (value is Iterable && value is! String) {
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  final normalized = value.toString().trim();
  if (normalized.isEmpty) {
    return const [];
  }
  return [normalized];
}

class NetworkCache {
  final String cacheKey;

  final Uri uri;

  final Map<String, dynamic> requestHeaders;

  final Map<String, List<String>> responseHeaders;

  final Object? data;

  final DateTime time;

  final int size;

  NetworkCache({
    String? cacheKey,
    required this.uri,
    required this.requestHeaders,
    required this.responseHeaders,
    required this.data,
    required this.time,
    required this.size,
  }) : cacheKey =
           cacheKey ??
           buildNetworkCacheKey(
             method: 'GET',
             uri: uri,
             headers: requestHeaders,
           );
}

class NetworkCacheManager implements Interceptor {
  NetworkCacheManager._();

  static final NetworkCacheManager instance = NetworkCacheManager._();

  factory NetworkCacheManager() => instance;

  final Map<String, NetworkCache> _cache = {};
  final Map<String, Future<Response<dynamic>>> _validationRequests = {};

  @visibleForTesting
  NetworkCacheValidationFetcher? debugValidationFetcher;

  int size = 0;

  NetworkCache? getCache(String cacheKey) {
    final cache = _cache.remove(cacheKey);
    if (cache == null) {
      return null;
    }
    _cache[cacheKey] = cache;
    return cache;
  }

  void setCache(NetworkCache cache) {
    _removeCacheEntry(cache.cacheKey);
    if (cache.size <= 0 || cache.size > _maxNetworkCacheSize) {
      return;
    }
    _cache[cache.cacheKey] = cache;
    size += cache.size;
    _evictUntilWithinLimit();
  }

  void removeCache(Uri uri) {
    final keysToRemove = _cache.entries
        .where((entry) => entry.value.uri == uri)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in keysToRemove) {
      _removeCacheEntry(key);
    }
  }

  void clear() {
    _cache.clear();
    _validationRequests.clear();
    size = 0;
  }

  @visibleForTesting
  int get debugEntryCount => _cache.length;

  @visibleForTesting
  void debugResetForTesting() {
    clear();
    debugValidationFetcher = null;
  }

  @visibleForTesting
  Future<bool> debugValidateCacheForTesting(
    String cacheKey,
    NetworkCache cache,
    RequestOptions options,
  ) {
    return _validateCache(cacheKey, cache, options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.method != "GET") {
      return handler.next(err);
    }
    return handler.next(err);
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.method != "GET") {
      return handler.next(options);
    }

    final cacheKey = buildNetworkCacheKey(
      method: options.method,
      uri: options.uri,
      headers: options.headers,
    );
    final cache = getCache(cacheKey);
    final cacheTime = networkCacheTimeHeaderValue(options.headers);

    if (cache == null) {
      removeNetworkCacheTimeHeader(options.headers);
      return handler.next(options);
    }

    if (cacheTime == 'no') {
      removeNetworkCacheTimeHeader(options.headers);
      removeCache(options.uri);
      return handler.next(options);
    }

    final time = DateTime.now();
    final diff = time.difference(cache.time);
    if (cacheTime == 'long' && diff < const Duration(hours: 6)) {
      return handler.resolve(_cachedResponse(options, cache));
    } else if (diff < const Duration(seconds: 5)) {
      return handler.resolve(_cachedResponse(options, cache));
    } else if (diff < const Duration(hours: 2)) {
      try {
        if (await _validateCache(cacheKey, cache, options)) {
          return handler.resolve(_cachedResponse(options, cache));
        }
      } catch (e, s) {
        if (shouldContinueRequestAfterCacheValidationError(
          method: options.method,
        )) {
          Log.error(
            "Network Cache",
            "Failed to validate cache for ${options.uri}: $e",
            s,
          );
          _removeCacheEntry(cacheKey);
          removeNetworkCacheTimeHeader(options.headers);
          return handler.next(options);
        }
        rethrow;
      }
    }

    _removeCacheEntry(cacheKey);
    removeNetworkCacheTimeHeader(options.headers);
    handler.next(options);
  }

  static bool compareHeaders(Map<String, dynamic> a, Map<String, dynamic> b) {
    final normalizedA = normalizeNetworkCacheHeaders(a);
    final normalizedB = normalizeNetworkCacheHeaders(b);
    if (normalizedA.length != normalizedB.length) {
      return false;
    }
    for (final entry in normalizedA.entries) {
      final valuesB = normalizedB[entry.key];
      if (valuesB == null || valuesB.length != entry.value.length) {
        return false;
      }
      for (var i = 0; i < entry.value.length; i++) {
        if (entry.value[i] != valuesB[i]) {
          return false;
        }
      }
    }
    return true;
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    if (response.requestOptions.method != "GET") {
      return handler.next(response);
    }
    if (response.statusCode != null && response.statusCode! >= 400) {
      return handler.next(response);
    }
    final calculatedSize = _calculateSize(response.data);
    if (shouldStoreNetworkCacheEntrySize(calculatedSize)) {
      final cache = NetworkCache(
        cacheKey: buildNetworkCacheKey(
          method: response.requestOptions.method,
          uri: response.requestOptions.uri,
          headers: response.requestOptions.headers,
        ),
        uri: response.requestOptions.uri,
        requestHeaders: Map<String, dynamic>.from(
          response.requestOptions.headers,
        ),
        responseHeaders: Map<String, List<String>>.from(response.headers.map),
        data: response.data,
        time: DateTime.now(),
        size: calculatedSize!,
      );
      setCache(cache);
    }
    handler.next(response);
  }

  Future<bool> _validateCache(
    String cacheKey,
    NetworkCache cache,
    RequestOptions options,
  ) async {
    final validationRequest =
        _validationRequests[cacheKey] ?? _startValidation(cacheKey, options);
    final response = await validationRequest;
    return response.statusCode == 200 &&
        compareHeaders(cache.responseHeaders, response.headers.map);
  }

  Future<Response<dynamic>> _startValidation(
    String cacheKey,
    RequestOptions options,
  ) {
    final validationOptions = _buildCacheValidationOptions(options);
    final fetcher = debugValidationFetcher;
    late final Future<Response<dynamic>> request;
    if (fetcher == null) {
      request = AppDio().fetch(validationOptions);
    } else {
      request = fetcher(validationOptions);
    }
    _validationRequests[cacheKey] = request;
    unawaited(
      request
          .whenComplete(() {
            if (_validationRequests[cacheKey] == request) {
              _validationRequests.remove(cacheKey);
            }
          })
          .catchError((Object _) => Response<dynamic>(requestOptions: options)),
    );
    return request;
  }

  RequestOptions _buildCacheValidationOptions(RequestOptions options) {
    final headers = Map<String, dynamic>.from(options.headers);
    removeNetworkCacheTimeHeader(headers);
    headers.removeWhere(
      (key, _) =>
          key.toLowerCase() == Headers.contentLengthHeader ||
          key.toLowerCase() == Headers.contentTypeHeader,
    );
    return RequestOptions(
      method: "HEAD",
      path: options.path,
      baseUrl: options.baseUrl,
      queryParameters: Map<String, dynamic>.from(options.queryParameters),
      headers: headers,
      extra: Map<String, dynamic>.from(options.extra),
      preserveHeaderCase: options.preserveHeaderCase,
      responseType: ResponseType.plain,
      validateStatus: options.validateStatus,
      receiveDataWhenStatusError: options.receiveDataWhenStatusError,
      followRedirects: options.followRedirects,
      maxRedirects: options.maxRedirects,
      persistentConnection: options.persistentConnection,
      connectTimeout: options.connectTimeout,
      receiveTimeout: options.receiveTimeout,
      sendTimeout: options.sendTimeout,
      requestEncoder: options.requestEncoder,
      responseDecoder: options.responseDecoder,
      listFormat: options.listFormat,
    );
  }

  void _removeCacheEntry(String cacheKey) {
    final cache = _cache.remove(cacheKey);
    if (cache == null) {
      return;
    }
    size = (size - cache.size).clamp(0, 1 << 62);
  }

  void _evictUntilWithinLimit() {
    while (size > _maxNetworkCacheSize && _cache.isNotEmpty) {
      _removeCacheEntry(_cache.keys.first);
    }
  }

  Response<dynamic> _cachedResponse(
    RequestOptions options,
    NetworkCache cache,
  ) {
    return Response(
      requestOptions: options,
      data: cache.data,
      headers: Headers.fromMap(cache.responseHeaders)
        ..set('venera-cache', 'true'),
      statusCode: 200,
    );
  }

  static int? _calculateSize(Object? data) {
    if (data == null) {
      return 0;
    }
    if (data is Uint8List) {
      return data.length;
    }
    if (data is List<int>) {
      return data.length;
    }
    if (data is String) {
      if (data.trim().isEmpty) {
        return 0;
      }
      if (data.length < 512 && data.contains("IP address")) {
        return 0;
      }
      return data.length * 4;
    }
    if (data is Map) {
      return data.toString().length * 4;
    }
    return null;
  }
}
