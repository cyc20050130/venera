import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

final String workspaceRoot = Directory.current.path;

String workspacePath(String relativePath) {
  return p.normalize(p.join(workspaceRoot, relativePath));
}

DynamicLibrary openTestSqlite() {
  return DynamicLibrary.open(workspacePath('build/test-sqlite3/sqlite3.dll'));
}

String get zipDllSourcePath =>
    workspacePath('build/test-zip/shared/zip_flutter.dll');
