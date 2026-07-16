import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';
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

  test('reader decode width follows physical viewport width', () {
    expect(resolveReaderImageDecodeWidth(360, 3), 1080);
    expect(resolveReaderImageDecodeWidth(800, 1.5), 1200);
    expect(resolveReaderImageDecodeWidth(0, 3), isNull);
    expect(resolveReaderImageDecodeWidth(360, double.nan), isNull);
  });

  test('image decode target honors viewport width without upscaling', () {
    final resized = resolveImageDecodeTargetSize(
      2000,
      2000,
      preferredWidth: 1000,
    );
    expect(resized.width, 1000);
    expect(resized.height, 1000);

    final unchanged = resolveImageDecodeTargetSize(
      800,
      1200,
      preferredWidth: 1080,
    );
    expect(unchanged.width, 800);
    expect(unchanged.height, 1200);
  });

  test('conventional pages retain the decoded-pixel memory cap', () {
    final resized = resolveImageDecodeTargetSize(
      4000,
      4000,
      preferredWidth: 3000,
    );

    expect(
      resized.width! * resized.height!,
      lessThanOrEqualTo(BaseImageProvider.maxImagePixel),
    );
  });

  test('extremely tall pages retain physical viewport width', () {
    final resized = resolveImageDecodeTargetSize(
      2000,
      20000,
      preferredWidth: 1080,
    );

    expect(resized.width, 1080);
    expect(resized.height! / resized.width!, closeTo(10, 0.05));
  });

  test('reader image cache key includes its decode width', () {
    const compact = ReaderImageProvider(
      'image',
      'source',
      'comic',
      'chapter',
      1,
      enableResize: true,
      decodeWidth: 720,
    );
    const wide = ReaderImageProvider(
      'image',
      'source',
      'comic',
      'chapter',
      1,
      enableResize: true,
      decodeWidth: 1080,
    );

    expect(compact, isNot(wide));
  });
}
