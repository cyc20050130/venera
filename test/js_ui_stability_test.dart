import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/js_ui.dart';

void main() {
  test('normalizeJsDialogActions tolerates malformed source UI actions', () {
    expect(normalizeJsDialogActions(null), isEmpty);
    expect(normalizeJsDialogActions('bad'), isEmpty);

    expect(
      normalizeJsDialogActions([
        {'text': 'OK', 'style': 'filled', 1: 'ignored'},
        'bad',
        {1: 'ignored'},
      ]),
      [
        {'text': 'OK', 'style': 'filled'},
      ],
    );
  });

  test('normalizeJsLaunchUrl accepts only non-empty string urls', () {
    expect(
      normalizeJsLaunchUrl(' https://example.com/a '),
      'https://example.com/a',
    );
    expect(normalizeJsLaunchUrl(''), isNull);
    expect(normalizeJsLaunchUrl('   '), isNull);
    expect(normalizeJsLaunchUrl(null), isNull);
    expect(normalizeJsLaunchUrl(1), isNull);
    expect(normalizeJsLaunchUrl(['https://example.com']), isNull);
  });

  test(
    'runJsUiCallbackSafely contains sync and async callback failures',
    () async {
      expect(runJsUiCallbackSafely(() => 'ok', label: 'test callback'), 'ok');

      expect(
        runJsUiCallbackSafely(
          () => throw StateError('sync failed'),
          label: 'test callback',
        ),
        isNull,
      );

      final asyncResult = runJsUiCallbackSafely(
        () => Future<void>.error(StateError('async failed')),
        label: 'test callback',
      );

      expect(asyncResult, isA<Future<void>>());
      await expectLater(asyncResult as Future<void>, completes);
    },
  );

  test('runJsInputValidatorSafely preserves validation semantics', () async {
    expect(runJsInputValidatorSafely(() => null), isNull);
    expect(runJsInputValidatorSafely(() => 'error'), 'error');
    expect(runJsInputValidatorSafely(() => 123), '123');

    final asyncPass = runJsInputValidatorSafely(
      () => Future<Object?>.value(null),
    );
    expect(asyncPass, isA<Future<String?>>());
    expect(await (asyncPass as Future<String?>), isNull);

    final asyncError = runJsInputValidatorSafely(
      () => Future<Object?>.value('async error'),
    );
    expect(await (asyncError as Future<String?>), 'async error');

    expect(
      runJsInputValidatorSafely(
        () => throw StateError('sync failed'),
        failureMessage: 'failed',
      ),
      'failed',
    );

    final asyncFailure = runJsInputValidatorSafely(
      () => Future<Object?>.error(StateError('async failed')),
      failureMessage: 'failed',
    );
    expect(await (asyncFailure as Future<String?>), 'failed');
  });
}
