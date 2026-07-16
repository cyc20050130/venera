import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';

void main() {
  late Directory tempDir;
  late Directory tempCacheDir;

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
    verifyDb.close();

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

  test('clear runs after already queued cache writes', () async {
    final manager = CacheManager();

    final write = manager.writeCache('queued-before-clear', [1, 2, 3, 4]);
    final clear = manager.clear();

    await Future.wait([write, clear]);

    expect(await manager.findCache('queued-before-clear'), isNull);
    expect(manager.currentSize, 0);

    final db = sqlite3.open('${tempDir.path}/cache.db');
    final rows = db.select('SELECT COUNT(*) AS count FROM cache;');
    db.close();

    expect(rows.first['count'], 0);
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
    db.close();

    final manager = CacheManager();
    final cached = await manager.findCache('cover-key');

    expect(cached, isNotNull);
    expect(await cached!.readAsBytes(), [1, 2, 3, 4]);
  });

  test('findCache drops malformed rows without crashing', () async {
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
      ['broken-key', '0', 'cached-file', 'not-an-int', null],
    );
    db.close();

    final manager = CacheManager();
    final cached = await manager.findCache('broken-key');

    expect(cached, isNull);

    final verifyDb = sqlite3.open('${tempDir.path}/cache.db');
    final rows = verifyDb.select('SELECT key FROM cache WHERE key = ?;', [
      'broken-key',
    ]);
    verifyDb.close();

    expect(rows, isEmpty);
  });

  test('expired malformed rows cannot delete files outside cache root', () async {
    final cacheDir = Directory(CacheManager.cachePath);
    await cacheDir.create(recursive: true);
    final outsideFile = File('${tempCacheDir.path}/outside-cache-file');
    await outsideFile.writeAsBytes([9, 8, 7, 6]);

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
        'escape-key',
        '..',
        outsideFile.uri.pathSegments.last,
        DateTime.now().millisecondsSinceEpoch - 60 * 1000,
        null,
      ],
    );
    db.close();

    final manager = CacheManager();
    await manager.checkCache();

    expect(await outsideFile.exists(), isTrue);
    expect(await outsideFile.readAsBytes(), [9, 8, 7, 6]);

    final verifyDb = sqlite3.open('${tempDir.path}/cache.db');
    final rows = verifyDb.select('SELECT key FROM cache WHERE key = ?;', [
      'escape-key',
    ]);
    verifyDb.close();

    expect(rows, isEmpty);
  });

  test('initial maintenance is scheduled explicitly', () async {
    final cacheDir = Directory(CacheManager.cachePath);
    await cacheDir.create(recursive: true);
    final orphan = File('${cacheDir.path}/orphan');
    await orphan.writeAsBytes([1, 2, 3, 4]);

    final manager = CacheManager();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(await orphan.exists(), isTrue);

    manager.scheduleInitialMaintenance(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(await orphan.exists(), isFalse);
  });

  test(
    'scheduled initial maintenance is cancelled when manager closes',
    () async {
      final cacheDir = Directory(CacheManager.cachePath);
      await cacheDir.create(recursive: true);
      final orphan = File('${cacheDir.path}/orphan');
      await orphan.writeAsBytes([1, 2, 3, 4]);

      final manager = CacheManager();
      manager.scheduleInitialMaintenance(const Duration(milliseconds: 40));
      manager.close();

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(await orphan.exists(), isTrue);
    },
  );

  test('scheduled maintenance is cancelled when manager closes', () async {
    final cacheDir = Directory(CacheManager.cachePath);
    await cacheDir.create(recursive: true);
    final orphan = File('${cacheDir.path}/orphan');
    await orphan.writeAsBytes([1, 2, 3, 4]);

    final manager = CacheManager();
    manager.scheduleMaintenance(const Duration(milliseconds: 40));
    manager.close();

    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(await orphan.exists(), isTrue);
  });

  test('serializes concurrent writes for the same key', () async {
    final manager = CacheManager();

    await Future.wait([
      manager.writeCache('same-key', List.filled(300 * 1024, 1)),
      manager.writeCache('same-key', List.filled(200 * 1024, 2)),
      manager.writeCache('same-key', List.filled(100 * 1024, 3)),
    ]);

    final cached = await manager.findCache('same-key');
    expect(cached, isNotNull);
    expect(await cached!.readAsBytes(), List.filled(100 * 1024, 3));

    final db = sqlite3.open('${tempDir.path}/cache.db');
    final rows = db.select(
      'SELECT COUNT(*) AS count FROM cache WHERE key = ?;',
      ['same-key'],
    );
    db.close();

    expect(rows.first['count'], 1);
    expect(manager.currentSize, 100 * 1024);
  });

  test('findCache throttles repeated expiry touches', () async {
    final manager = CacheManager();
    await manager.writeCache('touch-key', [1, 2, 3, 4]);

    final db = sqlite3.open('${tempDir.path}/cache.db');
    int expires() {
      return db.select('SELECT expires FROM cache WHERE key = ?;', [
            'touch-key',
          ]).first['expires']
          as int;
    }

    final firstExpires = expires();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final firstHit = await manager.findCache('touch-key');
    final secondExpires = expires();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final secondHit = await manager.findCache('touch-key');
    final thirdExpires = expires();
    db.close();

    expect(firstHit, isNotNull);
    expect(secondHit, isNotNull);
    expect(secondExpires, firstExpires);
    expect(thirdExpires, firstExpires);
  });
}
