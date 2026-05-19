import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

final String workspaceRoot = Directory.current.path;

String workspacePath(String relativePath) {
  return p.normalize(p.join(workspaceRoot, relativePath));
}

String _resolveExistingPath(List<String> candidates, String label) {
  for (final candidate in candidates) {
    final path = workspacePath(candidate);
    if (File(path).existsSync()) {
      return path;
    }
  }
  throw StateError(
    'Missing $label. Tried: ${candidates.map(workspacePath).join(', ')}',
  );
}

DynamicLibrary openTestSqlite() {
  return DynamicLibrary.open(
    _resolveExistingPath([
      'build/test-sqlite3/sqlite3.dll',
      'build/windows/x64/runner/Release/sqlite3.dll',
      'build/windows/x64/plugins/sqlite3_flutter_libs/Release/sqlite3.dll',
    ], 'sqlite3.dll'),
  );
}

String get zipDllSourcePath =>
    _resolveExistingPath([
      'build/test-zip/shared/zip_flutter.dll',
      'build/windows/x64/plugins/zip_flutter/shared/Release/zip_flutter.dll',
      'build/windows/x64/runner/Release/zip_flutter.dll',
    ], 'zip_flutter.dll');
