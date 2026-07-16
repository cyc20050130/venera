import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera/utils/atomic_file.dart';

void main() {
  late Directory directory;
  late File file;
  late AtomicFileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-atomic-file-');
    file = File(path.join(directory.path, 'state.json'));
    store = AtomicFileStore(file);
  });

  tearDown(() => directory.delete(recursive: true));

  Map<String, dynamic> parseObject(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map) throw const FormatException('not an object');
    return Map<String, dynamic>.from(decoded);
  }

  test('write keeps the previous valid value as a backup', () async {
    await store.writeJson({'version': 1});
    await store.writeJson({'version': 2});

    expect(await store.readParsed(parseObject), {'version': 2});
    expect(jsonDecode(await store.backupFile.readAsString()), {'version': 1});
  });

  test(
    'read restores a valid backup when the current value is corrupt',
    () async {
      await store.writeJson({'version': 1});
      await store.writeJson({'version': 2});
      await file.writeAsString('{broken', flush: true);

      expect(await store.readParsed(parseObject), {'version': 1});
      expect(await store.backupFile.exists(), isFalse);
      expect(jsonDecode(await file.readAsString()), {'version': 1});
    },
  );

  test('recovery restores backup left after an interrupted rename', () async {
    await store.writeJson({'version': 1});
    await file.rename(store.backupFile.path);
    await store.temporaryFile.writeAsString('{partial', flush: true);

    await store.recoverInterruptedWrite();

    expect(jsonDecode(await file.readAsString()), {'version': 1});
    expect(await store.temporaryFile.exists(), isFalse);
  });
}
