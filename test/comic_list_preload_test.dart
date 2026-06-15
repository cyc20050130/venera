import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  test('comic list preload starts before the final visible item', () {
    expect(shouldTriggerComicListPreload(10, 20), isFalse);
    expect(shouldTriggerComicListPreload(11, 20), isTrue);
    expect(shouldTriggerComicListPreload(19, 20), isTrue);
  });

  test('comic list preload ignores invalid or empty indexes', () {
    expect(shouldTriggerComicListPreload(-1, 20), isFalse);
    expect(shouldTriggerComicListPreload(0, 0), isFalse);
  });

  test('comic list preload threshold can be tuned for compact lists', () {
    expect(
      shouldTriggerComicListPreload(6, 10, remainingItemThreshold: 2),
      isFalse,
    );
    expect(
      shouldTriggerComicListPreload(7, 10, remainingItemThreshold: 2),
      isTrue,
    );
  });
}
