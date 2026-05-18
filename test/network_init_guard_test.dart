import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';

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
}
