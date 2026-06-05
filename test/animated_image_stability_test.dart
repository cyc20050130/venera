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
}
