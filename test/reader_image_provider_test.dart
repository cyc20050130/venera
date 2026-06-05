import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';

void main() {
  test('custom image processing flag tolerates synced malformed settings', () {
    expect(shouldEnableCustomImageProcessing(true), isTrue);
    expect(shouldEnableCustomImageProcessing(false), isFalse);
    expect(shouldEnableCustomImageProcessing('true'), isTrue);
    expect(shouldEnableCustomImageProcessing('false'), isFalse);
    expect(shouldEnableCustomImageProcessing(1), isTrue);
    expect(shouldEnableCustomImageProcessing(0), isFalse);
    expect(shouldEnableCustomImageProcessing('bad'), isFalse);
    expect(shouldEnableCustomImageProcessing(['true']), isFalse);
    expect(shouldEnableCustomImageProcessing(null), isFalse);
  });

  test('custom image future errors instead of waiting forever', () async {
    await expectLater(
      resolveCustomImageFuture(
        Future<Uint8List>.error(StateError('boom')),
        checkStop: () {},
        pollInterval: Duration.zero,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('custom image future calls onCancel when loading stops', () async {
    final completer = Completer<Uint8List>();
    var canceled = false;

    await expectLater(
      resolveCustomImageFuture(
        completer.future,
        checkStop: () => throw StateError('stopped'),
        onCancel: () => canceled = true,
        pollInterval: Duration.zero,
      ),
      throwsA(isA<StateError>()),
    );

    expect(canceled, isTrue);
  });
}
