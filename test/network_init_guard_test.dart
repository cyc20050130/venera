import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';

void main() {
  setUp(() {
    AppDio.debugResetNetworkState();
  });

  tearDown(() {
    AppDio.debugResetNetworkState();
  });

  test(
    'fetch throws a clear error when the network runtime is unavailable',
    () async {
      AppDio.markNetworkInitializationFailed(StateError('rhttp init failed'));

      final adapter = RHttpAdapter();
      final options = RequestOptions(
        path: 'https://example.com',
        method: 'GET',
      );

      await expectLater(
        () => adapter.fetch(options, null, null),
        throwsA(
          isA<DioException>()
              .having(
                (e) => e.message,
                'message',
                contains('HTTP runtime failed to initialize'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('rhttp init failed'),
              ),
        ),
      );
    },
  );

  test('markNetworkInitialized clears previous initialization errors', () {
    AppDio.markNetworkInitializationFailed(StateError('rhttp init failed'));

    AppDio.markNetworkInitialized();

    expect(AppDio.isNetworkReady, isTrue);
    expect(AppDio.networkUnavailableReason, isNull);
  });

  test('AppDio tolerates initialized app before cookie jar is ready', () async {
    final previousInitialized = App.isInitialized;
    final previousCookieJar = SingleInstanceCookieJar.instance;
    final previousMuted = Log.isMuted;
    final tempDir = await Directory.systemTemp.createTemp('venera-appdio-');
    App.isInitialized = true;
    App.dataPath = tempDir.path;
    Log.isMuted = true;
    SingleInstanceCookieJar.instance = null;
    addTearDown(() {
      App.isInitialized = previousInitialized;
      SingleInstanceCookieJar.instance = previousCookieJar;
      Log.isMuted = previousMuted;
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final dio = AppDio();

    expect(dio.interceptors.whereType<CookieManagerSql>(), isEmpty);
  });

  test(
    'ensureNetworkReady lazily initializes in the current isolate',
    () async {
      var initCount = 0;
      AppDio.debugSetNetworkInitializer(() async {
        initCount++;
      });

      await AppDio.ensureNetworkReady();
      await AppDio.ensureNetworkReady();

      expect(AppDio.isNetworkReady, isTrue);
      expect(initCount, 1);
    },
  );

  test('ensureNetworkReady also initializes inside worker isolates', () async {
    final didInitialize = await Isolate.run(() async {
      AppDio.debugSetNetworkInitializer(() async {});
      await AppDio.ensureNetworkReady();
      return AppDio.isNetworkReady;
    });

    expect(didInitialize, isTrue);
  });

  test(
    'prevent-parallel request key normalizes query and selected headers',
    () {
      final first = buildPreventParallelRequestKey(
        method: 'GET',
        path: 'https://example.com/a?b=2&a=1',
        headers: {
          'Prevent-Parallel': 'true',
          'User-Agent': ' UA ',
          'Cache-Time': 'long',
          'Accept': ['image/*', ' */* '],
        },
      );
      final second = buildPreventParallelRequestKey(
        method: 'get',
        path: 'https://EXAMPLE.com/a',
        queryParameters: {'a': '1', 'b': '2'},
        headers: {
          'user-agent': ['UA'],
          'accept': ['*/*', 'image/*'],
        },
      );

      expect(first, second);
    },
  );

  test(
    'prevent-parallel request key distinguishes query and header changes',
    () {
      final base = buildPreventParallelRequestKey(
        method: 'GET',
        path: 'https://example.com/a?id=1',
        headers: {'User-Agent': 'UA'},
      );

      expect(
        base,
        isNot(
          buildPreventParallelRequestKey(
            method: 'GET',
            path: 'https://example.com/a?id=2',
            headers: {'User-Agent': 'UA'},
          ),
        ),
      );
      expect(
        base,
        isNot(
          buildPreventParallelRequestKey(
            method: 'GET',
            path: 'https://example.com/a?id=1',
            headers: {'User-Agent': 'Other'},
          ),
        ),
      );
    },
  );

  test('prevent-parallel request key only applies to GET', () {
    expect(
      buildPreventParallelRequestKey(
        method: 'POST',
        path: 'https://example.com/a',
        headers: {'prevent-parallel': 'true'},
      ),
      isNull,
    );
  });

  test('prevent-parallel request key ignores malformed uri inputs', () {
    expect(
      buildPreventParallelRequestKey(
        method: 'GET',
        path: 'https://example.com/%ZZ',
        headers: {'prevent-parallel': 'true'},
      ),
      isNull,
    );
    expect(
      buildPreventParallelRequestKey(
        method: 'GET',
        path: '/a',
        baseUrl: 'https://example.com/%ZZ',
        headers: {'prevent-parallel': 'true'},
      ),
      isNull,
    );
  });

  test('DNS override setting tolerates synced non-bool values', () {
    expect(shouldEnableDnsOverrides(true), isTrue);
    expect(shouldEnableDnsOverrides(false), isFalse);
    expect(shouldEnableDnsOverrides('true'), isTrue);
    expect(shouldEnableDnsOverrides('false'), isFalse);
    expect(shouldEnableDnsOverrides(1), isTrue);
    expect(shouldEnableDnsOverrides(0), isFalse);
    expect(shouldEnableDnsOverrides('bad'), isFalse);
    expect(shouldEnableDnsOverrides(['true']), isFalse);
    expect(shouldEnableDnsOverrides(null), isFalse);
  });

  test(
    'prevent-parallel works from BaseOptions headers without leaking header',
    () async {
      final adapter = _SlowAdapter();
      final dio = AppDio(
        BaseOptions(headers: {'prevent-parallel': 'true', 'User-Agent': 'UA'}),
      )..httpClientAdapter = adapter;

      final first = dio.get<String>('https://example.com/a?id=1');
      await Future<void>.delayed(Duration.zero);
      final second = dio.get<String>('https://example.com/a?id=1');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(adapter.requests, hasLength(1));
      expect(adapter.maxConcurrentRequests, 1);

      adapter.releaseNext();
      await first;
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(adapter.requests, hasLength(2));
      adapter.releaseNext();
      await second;

      expect(adapter.maxConcurrentRequests, 1);
      expect(
        adapter.requests.every(
          (headers) => !headers.keys.any(
            (key) => key.toLowerCase() == 'prevent-parallel',
          ),
        ),
        isTrue,
      );
      expect(
        adapter.requests.every((headers) => headers['User-Agent'] == 'UA'),
        isTrue,
      );
    },
  );

  test(
    'prevent-parallel does not mutate shared BaseOptions headers while waiting',
    () async {
      final headers = {'prevent-parallel': 'true', 'User-Agent': 'UA'};
      final adapter = _SlowAdapter();
      final dio = AppDio(BaseOptions(headers: headers))
        ..httpClientAdapter = adapter;

      final first = dio.get<String>('https://example.com/a?id=1');
      await Future<void>.delayed(Duration.zero);
      final second = dio.get<String>('https://example.com/a?id=1');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(headers['prevent-parallel'], 'true');
      expect(dio.options.headers['prevent-parallel'], 'true');
      expect(adapter.requests, hasLength(1));

      adapter.releaseNext();
      await first;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(headers['prevent-parallel'], 'true');
      expect(dio.options.headers['prevent-parallel'], 'true');

      adapter.releaseNext();
      await second;
      expect(adapter.maxConcurrentRequests, 1);
      expect(headers['prevent-parallel'], 'true');
      expect(dio.options.headers['prevent-parallel'], 'true');
    },
  );

  test(
    'request headers can disable BaseOptions prevent-parallel flag',
    () async {
      final adapter = _SlowAdapter();
      final dio = AppDio(
        BaseOptions(headers: {'prevent-parallel': 'true', 'User-Agent': 'UA'}),
      )..httpClientAdapter = adapter;

      final first = dio.get<String>(
        'https://example.com/a?id=1',
        options: Options(headers: {'prevent-parallel': 'false'}),
      );
      await Future<void>.delayed(Duration.zero);
      final second = dio.get<String>(
        'https://example.com/a?id=1',
        options: Options(headers: {'prevent-parallel': 'false'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(adapter.requests, hasLength(2));
      expect(adapter.maxConcurrentRequests, 2);
      expect(
        adapter.requests.every(
          (headers) => !headers.keys.any(
            (key) => key.toLowerCase() == 'prevent-parallel',
          ),
        ),
        isTrue,
      );

      adapter.releaseNext();
      adapter.releaseNext();
      await Future.wait([first, second]);
    },
  );
}

class _SlowAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> requests = [];
  final List<Completer<void>> _releases = [];
  int _activeRequests = 0;
  int maxConcurrentRequests = 0;

  void releaseNext() {
    final release = _releases.removeAt(0);
    if (!release.isCompleted) {
      release.complete();
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(Map<String, dynamic>.from(options.headers));
    _activeRequests++;
    maxConcurrentRequests = maxConcurrentRequests < _activeRequests
        ? _activeRequests
        : maxConcurrentRequests;
    final release = Completer<void>();
    _releases.add(release);
    await release.future;
    _activeRequests--;
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}
