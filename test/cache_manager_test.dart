import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';

import 'test_native_paths.dart';

void main() {
  late Directory tempDir;
  late Directory tempCacheDir;

  setUpAll(() {
    open.overrideFor(OperatingSystem.windows, openTestSqlite);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-cache-test-');
    tempCacheDir = await Directory.systemTemp.createTemp('venera-cache-root-');
    App.dataPath = tempDir.path;
    App.cachePath = tempCacheDir.path;
    CacheManager.instance?.close();
  });

  tearDown(() async {
    CacheManager.instance?.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    if (await tempCacheDir.exists()) {
      await tempCacheDir.delete(recursive: true);
    }
  });

  test('rebuilds cache database when cache.db is corrupted', () async {
    final dbFile = File('${tempDir.path}/cache.db');
    await dbFile.writeAsBytes(List<int>.generate(128, (i) => i));

    final manager = CacheManager();
    await Future.delayed(const Duration(milliseconds: 100));

    final verifyDb = sqlite3.open(dbFile.path);
    final rows = verifyDb.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'cache';",
    );
    verifyDb.dispose();

    expect(rows, isNotEmpty);
    expect(manager.currentSize, greaterThanOrEqualTo(0));
  });

  test('shrinks cache back under the configured limit', () async {
    final manager = CacheManager();
    manager.setLimitSize(1);

    await manager.writeCache('a', List.filled(700 * 1024, 1));
    await manager.writeCache('b', List.filled(700 * 1024, 2));
    await manager.checkCache();

    expect(manager.currentSize, lessThanOrEqualTo(1024 * 1024));
  });

  test('clear tolerates a missing cache directory', () async {
    final manager = CacheManager();
    final dir = Directory(CacheManager.cachePath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }

    await manager.clear();

    expect(await Directory(CacheManager.cachePath).exists(), isTrue);
    expect(manager.currentSize, 0);
  });

  test('findCache stays available while initial maintenance runs', () async {
    final cacheDir = Directory(CacheManager.cachePath);
    await cacheDir.create(recursive: true);
    final nestedDir = Directory('${cacheDir.path}/0');
    await nestedDir.create(recursive: true);
    final file = File('${nestedDir.path}/cached-file');
    await file.writeAsBytes([1, 2, 3, 4]);

    final db = sqlite3.open('${tempDir.path}/cache.db');
    db.execute('''
      CREATE TABLE cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    db.execute(
      'INSERT INTO cache (key, dir, name, expires, type) VALUES (?, ?, ?, ?, ?)',
      [
        'cover-key',
        '0',
        'cached-file',
        DateTime.now().millisecondsSinceEpoch + 60 * 1000,
        null,
      ],
    );
    db.dispose();

    final manager = CacheManager();
    final cached = await manager.findCache('cover-key');

    expect(cached, isNotNull);
    expect(await cached!.readAsBytes(), [1, 2, 3, 4]);
  });
}
