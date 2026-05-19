import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';

import 'test_native_paths.dart';

void main() {
  test('openTestSqlite resolves an existing sqlite runtime', () {
    final library = openTestSqlite();
    expect(library, isA<DynamicLibrary>());
  });

  test('zipDllSourcePath resolves an existing zip runtime', () {
    expect(zipDllSourcePath, isNotEmpty);
  });
}
