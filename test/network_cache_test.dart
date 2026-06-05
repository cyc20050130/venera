import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cache.dart';

void main() {
  setUp(() {
    NetworkCacheManager().debugResetForTesting();
  });

  tearDown(() {
    NetworkCacheManager().debugResetForTesting();
  });

  test('network cache validation failures fall back to a normal request', () {
    expect(
      shouldContinueRequestAfterCacheValidationError(method: 'GET'),
      isTrue,
    );
    expect(
      shouldContinueRequestAfterCacheValidationError(method: 'POST'),
      isFalse,
    );
  });

  test('normalizes uri query and headers for stable cache keys', () {
    final uriA = Uri.parse('HTTPS://Example.COM/a?b=2&a=1');
    final uriB = Uri.parse('https://example.com/a?a=1&b=2');

    expect(normalizeNetworkCacheUri(uriA), normalizeNetworkCacheUri(uriB));
    expect(
      normalizeNetworkCacheHeaders({
        'User-Agent': ' UA ',
        'Cache-Time': 'long',
        'CF-RAY': 'volatile',
        'Accept': ['image/*', ' */* '],
      }),
      {
        'accept': ['image/*', '*/*'],
        'user-agent': ['UA'],
      },
    );
    expect(
      buildNetworkCacheKey(
        method: 'get',
        uri: uriA,
        headers: {'User-Agent': 'UA'},
      ),
      buildNetworkCacheKey(
        method: 'GET',
        uri: uriB,
        headers: {
          'user-agent': ['UA'],
        },
      ),
    );
  });

  test('cache key distinguishes meaningful query and header differences', () {
    final baseUri = Uri.parse('https://example.com/a?id=1');
    final otherUri = Uri.parse('https://example.com/a?id=2');

    final baseKey = buildNetworkCacheKey(
      method: 'GET',
      uri: baseUri,
      headers: {'User-Agent': 'UA'},
    );

    expect(
      baseKey,
      isNot(
        buildNetworkCacheKey(
          method: 'GET',
          uri: otherUri,
          headers: {'User-Agent': 'UA'},
        ),
      ),
    );
    expect(
      baseKey,
      isNot(
        buildNetworkCacheKey(
          method: 'GET',
          uri: baseUri,
          headers: {'User-Agent': 'Other'},
        ),
      ),
    );
  });

  test('evicts after insert and skips entries that are too large', () {
    final manager = NetworkCacheManager();
    final uri = Uri.parse('https://example.com/cache');

    for (var i = 0; i < 11; i++) {
      final key = buildNetworkCacheKey(
        method: 'GET',
        uri: uri.replace(queryParameters: {'page': '$i'}),
        headers: const {},
      );
      manager.setCache(
        NetworkCache(
          cacheKey: key,
          uri: uri.replace(queryParameters: {'page': '$i'}),
          requestHeaders: const {},
          responseHeaders: const {},
          data: Uint8List(1024 * 1024),
          time: DateTime.now(),
          size: 1024 * 1024,
        ),
      );
    }

    expect(manager.size, lessThanOrEqualTo(10 * 1024 * 1024));
    expect(manager.debugEntryCount, 10);

    manager.setCache(
      NetworkCache(
        cacheKey: 'oversized',
        uri: uri,
        requestHeaders: const {},
        responseHeaders: const {},
        data: Uint8List(11 * 1024 * 1024),
        time: DateTime.now(),
        size: 11 * 1024 * 1024,
      ),
    );

    expect(manager.getCache('oversized'), isNull);
  });

  test('cache entry size helper rejects empty and oversized entries', () {
    expect(calculateNetworkCacheObjectSize(null), 0);
    expect(calculateNetworkCacheObjectSize(''), 0);
    expect(calculateNetworkCacheObjectSize(Uint8List(16)), 16);
    expect(shouldStoreNetworkCacheEntrySize(0), isFalse);
    expect(shouldStoreNetworkCacheEntrySize(1024), isTrue);
    expect(shouldStoreNetworkCacheEntrySize(1024 * 1024), isFalse);
  });

  test('HEAD validation requests are shared per cache key', () async {
    final manager = NetworkCacheManager();
    final requestOptions = RequestOptions(
      path: 'https://example.com/image',
      method: 'GET',
      headers: const {'User-Agent': 'UA'},
    );
    final cacheKey = buildNetworkCacheKey(
      method: requestOptions.method,
      uri: requestOptions.uri,
      headers: requestOptions.headers,
    );
    final cache = NetworkCache(
      cacheKey: cacheKey,
      uri: requestOptions.uri,
      requestHeaders: requestOptions.headers,
      responseHeaders: const {
        'etag': ['same'],
      },
      data: Uint8List(4),
      time: DateTime.now().subtract(const Duration(minutes: 1)),
      size: 4,
    );

    var validationCalls = 0;
    final completer = Completer<Response<dynamic>>();
    manager.debugValidationFetcher = (options) {
      validationCalls++;
      expect(options.method, 'HEAD');
      return completer.future;
    };

    final first = manager.debugValidateCacheForTesting(
      cacheKey,
      cache,
      requestOptions,
    );
    final second = manager.debugValidateCacheForTesting(
      cacheKey,
      cache,
      requestOptions,
    );

    await Future<void>.delayed(Duration.zero);
    expect(validationCalls, 1);

    completer.complete(
      Response<dynamic>(
        requestOptions: requestOptions.copyWith(method: 'HEAD'),
        statusCode: 200,
        headers: Headers.fromMap({
          'ETag': ['same'],
        }),
      ),
    );

    expect(await first, isTrue);
    expect(await second, isTrue);
  });

  test('HEAD validation request strips body and control headers', () async {
    final manager = NetworkCacheManager();
    final requestOptions = RequestOptions(
      path: 'https://example.com/image',
      method: 'GET',
      data: Uint8List.fromList([1, 2, 3]),
      headers: {
        'User-Agent': 'UA',
        'Cache-Time': 'long',
        Headers.contentTypeHeader: Headers.jsonContentType,
        Headers.contentLengthHeader: '3',
      },
    );
    final cacheKey = buildNetworkCacheKey(
      method: requestOptions.method,
      uri: requestOptions.uri,
      headers: requestOptions.headers,
    );
    final cache = NetworkCache(
      cacheKey: cacheKey,
      uri: requestOptions.uri,
      requestHeaders: requestOptions.headers,
      responseHeaders: const {
        'etag': ['same'],
      },
      data: Uint8List(4),
      time: DateTime.now().subtract(const Duration(minutes: 1)),
      size: 4,
    );

    manager.debugValidationFetcher = (options) async {
      expect(options.method, 'HEAD');
      expect(options.data, isNull);
      expect(options.responseType, ResponseType.plain);
      expect(
        options.headers.keys,
        isNot(contains(equalsIgnoringCase('cache-time'))),
      );
      expect(
        options.headers.keys,
        isNot(contains(equalsIgnoringCase(Headers.contentTypeHeader))),
      );
      expect(
        options.headers.keys,
        isNot(contains(equalsIgnoringCase(Headers.contentLengthHeader))),
      );
      return Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        headers: Headers.fromMap({
          'ETag': ['same'],
        }),
      );
    };

    expect(
      await manager.debugValidateCacheForTesting(
        cacheKey,
        cache,
        requestOptions,
      ),
      isTrue,
    );
  });

  test('cache-time header controls cache case-insensitively', () async {
    final dio = Dio()
      ..interceptors.add(NetworkCacheManager())
      ..httpClientAdapter = _FakeCacheAdapter();

    final uri = Uri.parse('https://example.com/cached');

    final first = await dio.getUri<String>(uri);
    expect(first.data, 'network-1');

    final cached = await dio.getUri<String>(
      uri,
      options: Options(headers: {'Cache-Time': 'long'}),
    );
    expect(cached.data, 'network-1');
    expect(cached.headers.value('venera-cache'), 'true');

    final refreshed = await dio.getUri<String>(
      uri,
      options: Options(headers: {'Cache-Time': 'no'}),
    );
    expect(refreshed.data, 'network-2');

    final adapter = dio.httpClientAdapter as _FakeCacheAdapter;
    expect(adapter.requests, hasLength(2));
    expect(
      adapter.requests.every(
        (headers) =>
            !headers.keys.any((key) => key.toLowerCase() == 'cache-time'),
      ),
      isTrue,
    );
  });
}

class _FakeCacheAdapter implements HttpClientAdapter {
  int _count = 0;
  final List<Map<String, dynamic>> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(Map<String, dynamic>.from(options.headers));
    _count++;
    return ResponseBody.fromString(
      'network-$_count',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
