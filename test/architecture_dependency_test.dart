import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('foundation and network do not add new UI dependencies', () {
    final libDirectory = Directory('lib');
    final guardedDirectories = [
      Directory(p.join(libDirectory.path, 'foundation')),
      Directory(p.join(libDirectory.path, 'network')),
    ];
    final knownLegacyEdges = <String>{
      'foundation/bootstrap.dart -> pages/comic_source_page.dart',
      'foundation/bootstrap.dart -> pages/follow_updates_page.dart',
      'foundation/bootstrap.dart -> pages/settings/settings_page.dart',
      'foundation/comic_source/comic_source.dart -> pages/category_comics_page.dart',
      'foundation/comic_source/comic_source.dart -> pages/search_result_page.dart',
      'foundation/context.dart -> components/components.dart',
      'foundation/favorites.dart -> pages/follow_updates_page.dart',
      'foundation/js_engine.dart -> components/js_ui.dart',
      'foundation/local.dart -> pages/reader/reader.dart',
      'network/cloudflare.dart -> pages/webview.dart',
    };
    final importPattern = RegExp(
      r'''^\s*import\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );
    final unexpectedEdges = <String>[];

    for (final directory in guardedDirectories) {
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        final importer = p
            .relative(entity.path, from: libDirectory.path)
            .replaceAll('\\', '/');
        for (final match in importPattern.allMatches(source)) {
          final uri = match.group(1)!;
          final String imported;
          if (uri.startsWith('package:venera/')) {
            imported = uri.substring('package:venera/'.length);
          } else if (!uri.contains(':')) {
            imported = p
                .relative(
                  p.normalize(p.join(entity.parent.path, uri)),
                  from: libDirectory.path,
                )
                .replaceAll('\\', '/');
          } else {
            continue;
          }
          if (!imported.startsWith('pages/') &&
              !imported.startsWith('components/')) {
            continue;
          }
          final edge = '$importer -> $imported';
          if (!knownLegacyEdges.contains(edge)) {
            unexpectedEdges.add(edge);
          }
        }
      }
    }

    expect(
      unexpectedEdges,
      isEmpty,
      reason:
          'Domain/infrastructure code must not depend on UI. Move the shared '
          'contract below the UI layer or inject the UI behavior. Existing '
          'legacy edges are explicitly baselined and should be removed over time.',
    );
  });
}
