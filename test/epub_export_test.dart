import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/epub.dart';

void main() {
  test('epub image manifest href includes extension separator', () {
    expect(epubImageManifestHref(0, 'jpg'), 'OEBPS/images/img0.jpg');
    expect(epubImageManifestHref(12, 'webp'), 'OEBPS/images/img12.webp');
  });

  test('escapeEpubXml escapes text and attribute delimiters', () {
    expect(
      escapeEpubXml('A&B <C> "D" \'E\''),
      'A&amp;B &lt;C&gt; &quot;D&quot; &apos;E&apos;',
    );
  });

  test('epub export uses operation scoped temp paths', () {
    final outPath = File('library/comic.epub').path;

    expect(
      buildEpubWorkingDirectory('cache', 'op-1'),
      '${Directory('cache').path}${Platform.pathSeparator}epub-op-1',
    );
    expect(
      buildEpubTemporaryOutputPath(outPath, 'op-1'),
      '${Directory('library').path}${Platform.pathSeparator}.comic.epub.op-1.tmp',
    );
  });
}
