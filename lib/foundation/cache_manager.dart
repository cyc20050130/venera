import 'dart:async';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  bool _maintenanceScheduled = false;
  bool _isChecking = false;
  bool _checkPending = false;
  Completer<void>? _checkCompleter;
  late final Future<void> _storeReady;
  Future<void> _maintenanceQueue = Future.value();
  final Set<String> _pendingManagedPaths = <String>{};
  static const _yieldEvery = 24;

  CacheManager._create() {
    _currentSize = 0;
    final initStopwatch = Stopwatch()..start();
    _initCacheStore();
    initStopwatch.stop();
    _logPerf('cache store ready', initStopwatch);
    _storeReady = Future.value();
    unawaited(_runInitialMaintenance());
  }

  /// Get the singleton instance of CacheManager.
  factory CacheManager() => instance ??= CacheManager._create();

  void _initCacheStore() {
    Directory(cachePath).createSync(recursive: true);
    final dbPath = '${App.dataPath}/cache.db';
    try {
      _db = sqlite3.open(dbPath);
      _db.execute('''
        CREATE TABLE IF NOT EXISTS cache (
          key TEXT PRIMARY KEY NOT NULL,
          dir TEXT NOT NULL,
          name TEXT NOT NULL,
          expires INTEGER NOT NULL,
          type TEXT
        )
      ''');
      _db.select('SELECT key, dir, name, expires FROM cache LIMIT 1;');
    } catch (e, s) {
      Log.error("CacheManager", "Failed to initialize cache DB: $e", s);
      try {
        try {
          _db.dispose();
        } catch (_) {
          // ignore dispose failure for partially initialized databases
        }
        if (File(dbPath).existsSync()) {
          File(dbPath).deleteSync();
        }
        Directory(cachePath).deleteIfExistsSync(recursive: true);
      } catch (_) {
        // ignore cleanup failure and retry initialization below
      }
      Directory(cachePath).createSync(recursive: true);
      _db = sqlite3.open(dbPath);
      _db.execute('''
        CREATE TABLE IF NOT EXISTS cache (
          key TEXT PRIMARY KEY NOT NULL,
          dir TEXT NOT NULL,
          name TEXT NOT NULL,
          expires INTEGER NOT NULL,
          type TEXT
        )
      ''');
    }
  }

  Future<void> _runInitialMaintenance() async {
    final stopwatch = Stopwatch()..start();
    try {
      await _enqueueMaintenance(() async {
        final scanResult = await _scanDir(cachePath);
        _currentSize = scanResult.$1;
        await _cleanupUnmanagedFiles(scanResult.$2);
        await _runCheckCache();
      });
    } finally {
      stopwatch.stop();
      _logPerf(
        'initial maintenance complete',
        stopwatch,
        extra: 'currentSize=${_currentSize ?? -1}',
      );
    }
  }

  static Future<(int, List<String>)> _scanDir(String dir) async {
    return Isolate.run(() async {
      int totalSize = 0;
      List<String> filePaths = [];
      await for (var entity in Directory(dir).list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        try {
          totalSize += await entity.length();
          filePaths.add(p.normalize(entity.path));
        } catch (_) {
          // Ignore files disappearing during scan.
        }
      }
      return (totalSize, filePaths);
    });
  }

  Future<void> _cleanupUnmanagedFiles(List<String> filePaths) async {
    final scannedFiles = filePaths.toSet();
    for (var i = 0; i < filePaths.length; i++) {
      final filePath = filePaths[i];
      final file = File(filePath);
      final name = p.basename(filePath);
      final dir = p.basename(p.dirname(filePath));
      final res = _db.select(
        '''
        SELECT 1 FROM cache
        WHERE dir = ? AND name = ?
      ''',
        [dir, name],
      );
      if (res.isEmpty && !_pendingManagedPaths.contains(filePath)) {
        if (await file.exists()) {
          await file.delete();
        }
      }
      if ((i + 1) % _yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    final rows = _db.select('SELECT key, dir, name FROM cache;');
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final dbFilePath = p.normalize(
        p.join(cachePath, row["dir"] as String, row["name"] as String),
      );
      if (!scannedFiles.contains(dbFilePath) &&
          !_pendingManagedPaths.contains(dbFilePath)) {
        _db.execute('DELETE FROM cache WHERE key = ?;', [row["key"]]);
      }
      if ((i + 1) % _yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    _currentSize = await _recalculateManagedSize();
  }

  Future<int> _recalculateManagedSize() async {
    int total = 0;
    final rows = _db.select('SELECT dir, name FROM cache;');
    for (final row in rows) {
      final file = File('$cachePath/${row["dir"]}/${row["name"]}');
      if (await file.exists()) {
        total += await file.length();
      }
    }
    return total;
  }

  /// set cache size limit in MB
  void setLimitSize(int size) {
    _limitSize = size * 1024 * 1024;
  }

  void scheduleMaintenance([Duration delay = const Duration(seconds: 3)]) {
    if (_maintenanceScheduled) {
      return;
    }
    _maintenanceScheduled = true;
    Future.delayed(delay, () async {
      final stopwatch = Stopwatch()..start();
      try {
        await _storeReady;
        await _enqueueMaintenance(() async {
          final scanResult = await _scanDir(cachePath);
          _currentSize = scanResult.$1;
          await _cleanupUnmanagedFiles(scanResult.$2);
          await _runCheckCache();
        });
      } catch (e, s) {
        Log.error("CacheManager", "Failed to maintain cache: $e", s);
      } finally {
        stopwatch.stop();
        _logPerf(
          'scheduled maintenance complete',
          stopwatch,
          extra: 'currentSize=${_currentSize ?? -1}',
        );
        _maintenanceScheduled = false;
      }
    });
  }

  /// Write cache to disk.
  Future<void> writeCache(
    String key,
    List<int> data, [
    int duration = 7 * 24 * 60 * 60 * 1000,
  ]) async {
    await _storeReady;
    await _deleteInternal(key);
    dir = (dir + 1) % 100;
    final currentDir = dir;
    final name = md5.convert(key.codeUnits).toString();
    final filePath = p.normalize('$cachePath/$currentDir/$name');
    _pendingManagedPaths.add(filePath);
    try {
      final file = File(filePath);
      await file.create(recursive: true);
      await file.writeAsBytes(data);
      final expires = DateTime.now().millisecondsSinceEpoch + duration;
      _db.execute(
        '''
        INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
      ''',
        [key, currentDir.toString(), name, expires],
      );
      if (_currentSize != null) {
        _currentSize = (_currentSize! + data.length).clamp(0, 1 << 62);
      }
    } finally {
      _pendingManagedPaths.remove(filePath);
    }
    checkCacheIfRequired();
  }

  /// Find cache by key.
  /// If cache is expired, it will be deleted and return null.
  /// If cache is not found, it will return null.
  /// If cache is found, it will return the file, and update the expires time.
  Future<File?> findCache(String key) async {
    await _storeReady;
    final res = _db.select(
      '''
      SELECT * FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (res.isEmpty) {
      return null;
    }
    final row = res.first;
    final dir = row["dir"] as String;
    final name = row["name"] as String;
    final expires = row["expires"] as int;
    final file = File('$cachePath/$dir/$name');
    final now = DateTime.now().millisecondsSinceEpoch;
    if (expires < now) {
      _db.execute('DELETE FROM cache WHERE key = ?;', [key]);
      if (await file.exists()) {
        final size = await file.length();
        await file.delete();
        if (_currentSize != null) {
          _currentSize = (_currentSize! - size).clamp(0, 1 << 62);
        }
      }
      return null;
    }
    if (await file.exists()) {
      _db.execute(
        '''
        UPDATE cache
        SET expires = ?
        WHERE key = ?
      ''',
        [now + 7 * 24 * 60 * 60 * 1000, key],
      );
      return file;
    }
    _db.execute('DELETE FROM cache WHERE key = ?;', [key]);
    return null;
  }

  /// Only check cache if current size is greater than limit size.
  void checkCacheIfRequired() {
    if (_currentSize != null && _currentSize! > _limitSize) {
      unawaited(checkCache());
    }
  }

  /// Check cache size and delete expired cache.
  /// If current size is greater than limit size,
  /// delete cache until current size is less than limit size.
  Future<void> checkCache() async {
    await _storeReady;
    await _enqueueMaintenance(() async {
      if (_isChecking) {
        _checkPending = true;
        return _checkCompleter?.future ?? Future.value();
      }
      _isChecking = true;
      _checkCompleter = Completer<void>();
      try {
        do {
          _checkPending = false;
          await _runCheckCache();
        } while (_checkPending);
      } finally {
        _isChecking = false;
        _checkCompleter?.complete();
        _checkCompleter = null;
      }
    });
  }

  Future<void> _runCheckCache() async {
    final stopwatch = Stopwatch()..start();
    _currentSize ??= await _recalculateManagedSize();

    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = _db.select(
      '''
      SELECT key, dir, name
      FROM cache
      WHERE expires < ?
      ''',
      [now],
    );
    for (var i = 0; i < expired.length; i++) {
      final row = expired[i];
      final file = File('$cachePath/${row["dir"]}/${row["name"]}');
      if (await file.exists()) {
        final size = await file.length();
        await file.delete();
        _currentSize = (_currentSize! - size).clamp(0, 1 << 62);
      }
      _db.execute('DELETE FROM cache WHERE key = ?;', [row["key"]]);
      if ((i + 1) % _yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    while (_currentSize != null && _currentSize! > _limitSize) {
      final res = _db.select('''
        SELECT key, dir, name
        FROM cache
        ORDER BY expires ASC
        LIMIT 10
      ''');
      if (res.isEmpty) {
        await _rebuildCacheDirectory();
        break;
      }
      for (var i = 0; i < res.length; i++) {
        final row = res[i];
        final key = row["key"] as String;
        final file = File('$cachePath/${row["dir"]}/${row["name"]}');
        if (await file.exists()) {
          final size = await file.length();
          await file.delete();
          _currentSize = (_currentSize! - size).clamp(0, 1 << 62);
        }
        _db.execute('DELETE FROM cache WHERE key = ?;', [key]);
        if (_currentSize! <= _limitSize) {
          break;
        }
        if ((i + 1) % _yieldEvery == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    stopwatch.stop();
    _logPerf('check cache', stopwatch, extra: 'currentSize=${_currentSize ?? -1}');
  }

  Future<void> _rebuildCacheDirectory() async {
    await Directory(cachePath).deleteIfExists(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    _db.execute('DELETE FROM cache;');
    _currentSize = 0;
  }

  /// Delete cache by key.
  Future<void> delete(String key) async {
    await _storeReady;
    await _enqueueMaintenance(() => _deleteInternal(key));
  }

  Future<void> _deleteInternal(String key) async {
    final res = _db.select(
      '''
      SELECT * FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (res.isEmpty) {
      return;
    }
    final row = res.first;
    final file = File('$cachePath/${row["dir"]}/${row["name"]}');
    int fileSize = 0;
    if (await file.exists()) {
      fileSize = await file.length();
      await file.delete();
    }
    _db.execute('DELETE FROM cache WHERE key = ?;', [key]);
    if (_currentSize != null) {
      _currentSize = (_currentSize! - fileSize).clamp(0, 1 << 62);
    }
  }

  /// Delete all cache.
  Future<void> clear() async {
    await _storeReady;
    await _enqueueMaintenance(() async {
      await Directory(cachePath).deleteIfExists(recursive: true);
      Directory(cachePath).createSync(recursive: true);
      _db.execute('DELETE FROM cache;');
      _currentSize = 0;
    });
  }

  void close() {
    _db.dispose();
    _currentSize = null;
    _isChecking = false;
    _checkPending = false;
    instance = null;
  }

  void _logPerf(String label, Stopwatch stopwatch, {String? extra}) {
    if (!kDebugMode) {
      return;
    }
    final suffix = extra == null ? '' : ' $extra';
    Log.info(
      'CacheManager',
      '[perf] $label ${stopwatch.elapsedMilliseconds}ms$suffix',
    );
  }

  Future<T> _enqueueMaintenance<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _maintenanceQueue = _maintenanceQueue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    _maintenanceQueue = _maintenanceQueue.catchError((_) {});
    return completer.future;
  }
}
