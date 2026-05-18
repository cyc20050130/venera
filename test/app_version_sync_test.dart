import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('App.version matches pubspec build name', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final version = pubspec['version'] as String;
    final buildName = version.split('+').first;

    expect(App.version, buildName);
  });
}
