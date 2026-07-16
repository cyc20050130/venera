import 'dart:convert';
import 'dart:io';

/// Crash-safe storage for small state files.
///
/// Writes are flushed to a sibling temporary file, then the previous value is
/// retained as `.bak` while the temporary file is atomically renamed. Reads can
/// validate the current value and automatically restore the last valid backup.
final class AtomicFileStore {
  AtomicFileStore(this.file);

  final File file;

  File get temporaryFile => File('${file.path}.tmp');

  File get backupFile => File('${file.path}.bak');

  Future<void> writeString(String value) async {
    await file.parent.create(recursive: true);
    final temporary = temporaryFile;
    final backup = backupFile;
    await _deleteIfExists(temporary);
    await temporary.writeAsString(value, flush: true);

    await _deleteIfExists(backup);
    var movedCurrent = false;
    try {
      if (await file.exists()) {
        await file.rename(backup.path);
        movedCurrent = true;
      }
      await temporary.rename(file.path);
    } catch (error, stackTrace) {
      await _deleteIfExists(temporary);
      if (!await file.exists() && movedCurrent && await backup.exists()) {
        await backup.rename(file.path);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> writeJson(Object? value) => writeString(jsonEncode(value));

  Future<T?> readParsed<T>(T Function(String value) parse) async {
    await recoverInterruptedWrite();
    if (!await file.exists()) return null;
    try {
      return parse(await file.readAsString());
    } catch (error, stackTrace) {
      final backup = backupFile;
      if (!await backup.exists()) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      try {
        final backupValue = await backup.readAsString();
        final parsed = parse(backupValue);
        await _deleteIfExists(file);
        await backup.rename(file.path);
        return parsed;
      } catch (_) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  Future<void> recoverInterruptedWrite() async {
    final temporary = temporaryFile;
    final backup = backupFile;
    if (!await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    await _deleteIfExists(temporary);
  }

  Future<void> delete() async {
    await _deleteIfExists(temporaryFile);
    await _deleteIfExists(file);
    await _deleteIfExists(backupFile);
  }

  static Future<void> _deleteIfExists(File target) async {
    if (await target.exists()) {
      await target.delete();
    }
  }
}
