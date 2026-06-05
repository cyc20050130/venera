import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf.dart';

void main() {
  test('pdf export image filter excludes cover and non-image files', () async {
    final tempDir = await Directory.systemTemp.createTemp('venera-pdf-');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final cover = File('${tempDir.path}/cover.jpg');
    final image = File('${tempDir.path}/001.JPG');
    final text = File('${tempDir.path}/notes.txt');
    final nested = Directory('${tempDir.path}/chapter');
    await cover.writeAsBytes([1]);
    await image.writeAsBytes([1]);
    await text.writeAsString('notes');
    await nested.create();

    expect(isSupportedPdfExportImage(cover), isFalse);
    expect(isSupportedPdfExportImage(image), isTrue);
    expect(isSupportedPdfExportImage(text), isFalse);
    expect(isSupportedPdfExportImage(nested), isFalse);
  });
}
