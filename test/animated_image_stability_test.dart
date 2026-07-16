import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  test('animated image stream events are ignored after dispose', () {
    expect(shouldHandleAnimatedImageStreamEvent(mounted: true), isTrue);
    expect(shouldHandleAnimatedImageStreamEvent(mounted: false), isFalse);
  });

  test('animated image stream events are ignored after stream changes', () {
    expect(
      shouldHandleAnimatedImageStreamEvent(
        mounted: true,
        streamKey: 'old',
        currentStreamKey: 'new',
      ),
      isFalse,
    );
    expect(
      shouldHandleAnimatedImageStreamEvent(
        mounted: true,
        streamKey: 'same',
        currentStreamKey: 'same',
      ),
      isTrue,
    );
  });

  test('animated image retries transient failures with a bounded delay', () {
    expect(
      animatedImageRetryDelay(Exception('offline'), 0),
      const Duration(seconds: 2),
    );
    expect(
      animatedImageRetryDelay(Exception('offline'), 2),
      const Duration(seconds: 10),
    );
    expect(
      animatedImageRetryDelay(Exception('offline'), 99),
      const Duration(seconds: 30),
    );
    expect(
      animatedImageRetryDelay(Exception('Invalid Status Code: 404'), 0),
      isNull,
    );
  });
}
