import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/ext.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' as s;
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:venera/utils/file_type.dart';

export 'dart:io';
export 'dart:typed_data';

class IO {
  /// A global flag used to indicate whether the app is selecting files.
  ///
  /// Select file and other similar file operations will launch external programs,
  /// causing the app to lose focus. AppLifecycleState will be set to paused.
  static bool get isSelectingFiles => _selectingFilesCount > 0;

  static int _selectingFilesCount = 0;

  static void _beginSelectingFiles() {
    _selectingFilesCount++;
  }

  static Future<void> _endSelectingFilesAfter([
    Duration delay = const Duration(milliseconds: 100),
  ]) async {
    await Future.delayed(delay);
    if (_selectingFilesCount > 0) {
      _selectingFilesCount--;
    }
  }

  @visibleForTesting
  static void debugBeginSelectingFiles() {
    _beginSelectingFiles();
  }

  @visibleForTesting
  static Future<void> debugEndSelectingFilesAfter([
    Duration delay = Duration.zero,
  ]) {
    return _endSelectingFilesAfter(delay);
  }

  @visibleForTesting
  static int get debugSelectingFilesCount => _selectingFilesCount;

  @visibleForTesting
  static void debugResetSelectingFiles() {
    _selectingFilesCount = 0;
  }
}

class FilePath {
  const FilePath._();

  static String join(
    String path1,
    String path2, [
    String? path3,
    String? path4,
    String? path5,
  ]) {
    return p.join(path1, path2, path3, path4, path5);
  }
}

final Map<String, Future<void>> _outputFilePathQueues =
    <String, Future<void>>{};

String normalizeOutputFilePathForLock(String outputPath, {bool? windows}) {
  var normalizedPath = localFilePathFromUri(outputPath);
  try {
    normalizedPath = File(normalizedPath).absolute.path;
  } catch (_) {
    // Keep the original path if it cannot be represented by dart:io File.
  }
  if (windows ?? Platform.isWindows) {
    normalizedPath = normalizedPath.toLowerCase();
  }
  return normalizedPath;
}

Future<T> runOutputFilePathExclusively<T>(
  String outputPath,
  Future<T> Function() action,
) async {
  final key = normalizeOutputFilePathForLock(outputPath);
  final previous = _outputFilePathQueues[key] ?? Future<void>.value();
  final current = Completer<void>();
  final queued = previous.then(
    (_) => current.future,
    onError: (_) => current.future,
  );
  _outputFilePathQueues[key] = queued;
  try {
    await previous.catchError((_) {});
    return await action();
  } finally {
    if (!current.isCompleted) {
      current.complete();
    }
    if (identical(_outputFilePathQueues[key], queued)) {
      _outputFilePathQueues.remove(key);
    }
  }
}

@visibleForTesting
Future<T> debugRunOutputFilePathExclusively<T>(
  String outputPath,
  Future<T> Function() action,
) {
  return runOutputFilePathExclusively(outputPath, action);
}

bool isPathInsideDirectory(String path, String directory, {bool? windows}) {
  if (directory.trim().isEmpty) {
    return false;
  }
  final useWindows = windows ?? Platform.isWindows;
  final context = p.Context(
    style: useWindows ? p.Style.windows : p.Style.posix,
  );

  String normalize(String value) {
    var normalized = localFilePathFromUri(value, windows: useWindows);
    try {
      normalized = context.absolute(normalized);
    } catch (_) {
      // Keep the original path if it cannot be absolutized.
    }
    normalized = context.normalize(normalized);
    return useWindows ? normalized.toLowerCase() : normalized;
  }

  final normalizedPath = normalize(path);
  final normalizedDirectory = normalize(directory);
  return normalizedPath == normalizedDirectory ||
      context.isWithin(normalizedDirectory, normalizedPath);
}

Future<void> commitTemporaryOutputFile({
  required File tempFile,
  required File outputFile,
  required File backupFile,
}) {
  return runOutputFilePathExclusively(outputFile.path, () async {
    try {
      await backupFile.deleteIgnoreError();
      if (await outputFile.exists()) {
        await outputFile.rename(backupFile.path);
      }
      await tempFile.rename(outputFile.path);
      await backupFile.deleteIgnoreError();
    } catch (e, s) {
      if (!await outputFile.exists() && await backupFile.exists()) {
        await backupFile.rename(outputFile.path);
      } else {
        await backupFile.deleteIgnoreError();
      }
      await tempFile.deleteIgnoreError();
      Error.throwWithStackTrace(e, s);
    }
  });
}

String localFilePathFromUri(String pathOrUri, {bool? windows}) {
  if (!pathOrUri.startsWith('file://')) {
    return pathOrUri;
  }

  final useWindows = windows ?? Platform.isWindows;
  final withoutScheme = pathOrUri.substring('file://'.length);
  if (useWindows && RegExp(r'^[A-Za-z]:[/\\]').hasMatch(withoutScheme)) {
    return _decodeFileUriPath(withoutScheme).replaceAll('/', r'\');
  }
  try {
    return Uri.parse(pathOrUri).toFilePath(windows: useWindows);
  } catch (_) {
    var path = withoutScheme;
    if (useWindows && RegExp(r'^/[A-Za-z]:[/\\]').hasMatch(path)) {
      path = path.substring(1);
    }
    return _decodeFileUriPath(path);
  }
}

String _decodeFileUriPath(String value) {
  try {
    return Uri.decodeFull(value);
  } catch (_) {
    return value;
  }
}

extension FileSystemEntityExt on FileSystemEntity {
  /// Get the base name of the file or directory.
  String get name {
    return p.basename(path);
  }

  /// Delete the file or directory and ignore errors.
  Future<void> deleteIgnoreError({bool recursive = false}) async {
    try {
      await delete(recursive: recursive);
    } catch (e) {
      // ignore
    }
  }

  /// Delete the file or directory if it exists.
  Future<void> deleteIfExists({bool recursive = false}) async {
    if (existsSync()) {
      await delete(recursive: recursive);
    }
  }

  /// Delete the file or directory if it exists.
  void deleteIfExistsSync({bool recursive = false}) {
    if (existsSync()) {
      deleteSync(recursive: recursive);
    }
  }
}

extension FileExtension on File {
  /// Get the file extension, not including the dot.
  String get extension => path.split('.').last;

  /// Copy the file to the specified path using memory.
  ///
  /// This method prevents errors caused by files from different file systems.
  Future<void> copyMem(String newPath) async {
    var newFile = File(newPath);
    // Stream is not usable since [AndroidFile] does not support [openRead].
    await newFile.writeAsBytes(await readAsBytes());
  }

  /// Get the base name of the file without the extension.
  String get basenameWithoutExt {
    return p.basenameWithoutExtension(path);
  }
}

extension DirectoryExtension on Directory {
  /// Calculate the size of the directory.
  Future<int> get size async {
    if (!existsSync()) return 0;
    int total = 0;
    for (var f in listSync(recursive: true)) {
      if (FileSystemEntity.typeSync(f.path) == FileSystemEntityType.file) {
        total += await File(f.path).length();
      }
    }
    return total;
  }

  /// Change the base name of the directory.
  Directory renameX(String newName) {
    newName = sanitizeFileName(newName);
    return renameSync(path.replaceLast(name, newName));
  }

  File joinFile(String name) {
    return File(FilePath.join(path, name));
  }

  /// Delete the contents of the directory.
  void deleteContentsSync({recursive = true}) {
    if (!existsSync()) return;
    for (var f in listSync()) {
      f.deleteIfExistsSync(recursive: recursive);
    }
  }

  /// Delete the contents of the directory.
  Future<void> deleteContents({recursive = true}) async {
    if (!existsSync()) return;
    for (var f in listSync()) {
      await f.deleteIfExists(recursive: recursive);
    }
  }

  /// Create the directory. If the directory already exists, delete it first.
  void forceCreateSync() {
    if (existsSync()) {
      deleteSync(recursive: true);
    }
    createSync(recursive: true);
  }
}

/// Sanitize the file name. Remove invalid characters and trim the file name.
String sanitizeFileName(String fileName, {String? dir, int? maxLength}) {
  while (fileName.endsWith('.')) {
    fileName = fileName.substring(0, fileName.length - 1);
  }
  var length = maxLength ?? 255;
  if (dir != null) {
    if (!dir.endsWith('/') && !dir.endsWith('\\')) {
      dir = "$dir/";
    }
    length -= dir.length;
  }
  final invalidChars = RegExp(r'[<>:"/\\|?*]');
  final sanitizedFileName = fileName.replaceAll(invalidChars, ' ');
  var trimmedFileName = sanitizedFileName.trim();
  if (trimmedFileName.isEmpty) {
    throw Exception('Invalid File Name: Empty length.');
  }
  if (length <= 0) {
    throw Exception('Invalid File Name: Max length is less than 0.');
  }
  if (trimmedFileName.length > length) {
    trimmedFileName = trimmedFileName.substring(0, length);
  }
  return trimmedFileName;
}

/// Copy the **contents** of the source directory to the destination directory.
Future<void> copyDirectory(Directory source, Directory destination) async {
  List<FileSystemEntity> contents = source.listSync();
  for (FileSystemEntity content in contents) {
    String newPath = FilePath.join(destination.path, content.name);

    if (content is File) {
      var resultFile = File(newPath);
      resultFile.createSync();
      var data = content.readAsBytesSync();
      resultFile.writeAsBytesSync(data);
    } else if (content is Directory) {
      Directory newDirectory = Directory(newPath);
      newDirectory.createSync();
      await copyDirectory(content.absolute, newDirectory.absolute);
    }
  }
}

/// Copy the **contents** of the source directory to the destination directory.
/// This function is executed in an isolate to prevent the UI from freezing.
Future<void> copyDirectoryIsolate(
  Directory source,
  Directory destination,
) async {
  await Isolate.run(() => overrideIO(() => copyDirectory(source, destination)));
}

String findValidDirectoryName(String path, String directory) {
  var name = sanitizeFileName(directory);
  var dir = Directory("$path/$name");
  var i = 1;
  while (dir.existsSync() && dir.listSync().isNotEmpty) {
    name = sanitizeFileName("$directory($i)");
    dir = Directory("$path/$name");
    i++;
  }
  return name;
}

class DirectoryPicker {
  /// Pick a directory.
  ///
  /// The directory may not be usable after the instance is GCed.
  DirectoryPicker();

  static final _finalizer = Finalizer<String>((path) {
    if (isPathInsideDirectory(path, App.cachePath)) {
      Directory(path).deleteIgnoreError();
    }
    if (App.isIOS || App.isMacOS) {
      _methodChannel.invokeMethod("stopAccessingSecurityScopedResource");
    }
  });

  static const _methodChannel = MethodChannel("venera/method_channel");

  Future<Directory?> pickDirectory({bool directAccess = false}) async {
    IO._beginSelectingFiles();
    try {
      String? directory;
      if (App.isWindows || App.isLinux) {
        directory = await file_selector.getDirectoryPath();
      } else if (App.isAndroid) {
        directory = (await AndroidDirectory.pickDirectory())?.path;
        if (directory != null && directAccess) {
          // Native library does not have access to the directory. Copy it to cache.
          final cache = Directory(
            buildSelectedDirectoryCachePath(App.cachePath, const Uuid().v4()),
          );
          await cache.deleteIgnoreError(recursive: true);
          cache.createSync(recursive: true);
          await copyDirectoryIsolate(Directory(directory), cache);
          directory = cache.path;
        }
      } else {
        // ios, macos
        directory = await _methodChannel.invokeMethod<String?>(
          "getDirectoryPath",
        );
      }
      if (directory == null) return null;
      _finalizer.attach(this, directory);
      return Directory(directory);
    } finally {
      unawaited(IO._endSelectingFilesAfter());
    }
  }
}

class IOSDirectoryPicker {
  static const MethodChannel _channel = MethodChannel("venera/method_channel");

  // 调用 iOS 目录选择方法
  static Future<String?> selectDirectory() async {
    IO._beginSelectingFiles();
    try {
      final String? path = await _channel.invokeMethod('selectDirectory');
      return path;
    } catch (e) {
      // 返回报错信息
      return e.toString();
    } finally {
      unawaited(IO._endSelectingFilesAfter());
    }
  }
}

@visibleForTesting
bool isAllowedSelectedFileExtension(String path, List<String> extensions) {
  final extension = path.split('.').last.toLowerCase();
  return extensions.any((allowed) => allowed.toLowerCase() == extension);
}

@visibleForTesting
String buildSaveFileCachePath(
  String cachePath,
  String filename,
  String operationId,
) {
  return FilePath.join(
    cachePath,
    'save_file-$operationId',
    sanitizeFileName(filename),
  );
}

@visibleForTesting
String buildShareFileCachePath(
  String cachePath,
  String filename,
  String operationId,
) {
  return FilePath.join(
    cachePath,
    'share_file-$operationId',
    sanitizeFileName(filename),
  );
}

@visibleForTesting
String buildSelectedDirectoryCachePath(String cachePath, String operationId) {
  return FilePath.join(cachePath, 'selected_directory-$operationId');
}

Future<FileSelectResult?> selectFile({required List<String> ext}) async {
  IO._beginSelectingFiles();
  try {
    var extensions = App.isMacOS || App.isIOS ? null : ext;
    file_selector.XTypeGroup typeGroup = file_selector.XTypeGroup(
      label: 'files',
      extensions: extensions,
    );
    FileSelectResult? file;
    if (App.isAndroid) {
      const selectFileChannel = MethodChannel("venera/select_file");
      String mimeType = "*/*";
      if (ext.length == 1) {
        mimeType = FileType.fromExtension(ext[0]).mime;
        if (mimeType == "application/octet-stream") {
          mimeType = "*/*";
        }
      }
      var filePath = await selectFileChannel.invokeMethod(
        "selectFile",
        mimeType,
      );
      if (filePath == null) return null;
      file = FileSelectResult(filePath);
    } else {
      var xFile = await file_selector.openFile(
        acceptedTypeGroups: <file_selector.XTypeGroup>[typeGroup],
      );
      if (xFile == null) return null;
      file = FileSelectResult(xFile.path);
    }
    if (!isAllowedSelectedFileExtension(file.path, ext)) {
      App.rootContext.showMessage(
        message: "Invalid file type: ${file.path.split(".").last}",
      );
      return null;
    }
    return file;
  } finally {
    unawaited(IO._endSelectingFilesAfter());
  }
}

Future<String?> selectDirectory() async {
  IO._beginSelectingFiles();
  try {
    var path = await file_selector.getDirectoryPath();
    return path;
  } finally {
    unawaited(IO._endSelectingFilesAfter());
  }
}

// selectDirectoryIOS
Future<String?> selectDirectoryIOS() async {
  return IOSDirectoryPicker.selectDirectory();
}

Future<void> saveFile({
  Uint8List? data,
  required String filename,
  File? file,
}) async {
  if (data == null && file == null) {
    throw Exception("data and file cannot be null at the same time");
  }
  IO._beginSelectingFiles();
  Directory? cacheDir;
  try {
    if (data != null) {
      final cache = File(
        buildSaveFileCachePath(App.cachePath, filename, const Uuid().v4()),
      );
      cacheDir = cache.parent;
      await cacheDir.create(recursive: true);
      await cache.writeAsBytes(data);
      file = cache;
    }
    if (App.isMobile) {
      final params = SaveFileDialogParams(sourceFilePath: file!.path);
      await FlutterFileDialog.saveFile(params: params);
    } else {
      final result = await file_selector.getSaveLocation(
        suggestedName: filename,
      );
      if (result != null) {
        var xFile = file_selector.XFile(file!.path);
        await xFile.saveTo(result.path);
      }
    }
  } finally {
    await cacheDir?.deleteIgnoreError(recursive: true);
    unawaited(IO._endSelectingFilesAfter());
  }
}

final class _IOOverrides extends IOOverrides {
  @override
  Directory createDirectory(String path) {
    if (App.isAndroid) {
      var dir = AndroidDirectory.fromPathSync(path);
      if (dir == null) {
        return super.createDirectory(path);
      }
      return dir;
    } else {
      return super.createDirectory(path);
    }
  }

  @override
  File createFile(String path) {
    if (path.startsWith("file://")) {
      path = localFilePathFromUri(path);
    }
    if (App.isAndroid) {
      var f = AndroidFile.fromPathSync(path);
      if (f == null) {
        return super.createFile(path);
      }
      return f;
    } else {
      return super.createFile(path);
    }
  }
}

T overrideIO<T>(T Function() f) {
  return IOOverrides.runWithIOOverrides<T>(f, _IOOverrides());
}

class Share {
  static void shareFile({
    required Uint8List data,
    required String filename,
    required String mime,
  }) {
    Future<void> shareFuture;
    if (!App.isWindows) {
      shareFuture = s.SharePlus.instance.share(
        s.ShareParams(
          files: [s.XFile.fromData(data, mimeType: mime)],
          fileNameOverrides: [filename],
        ),
      );
    } else {
      final file = File(
        buildShareFileCachePath(App.cachePath, filename, const Uuid().v4()),
      );
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data);
      shareFuture = s.SharePlus.instance
          .share(s.ShareParams(files: [s.XFile(file.path)]))
          .whenComplete(() => file.parent.deleteIgnoreError(recursive: true));
    }
    unawaited(
      shareFuture.catchError((Object error, StackTrace stackTrace) {
        debugPrint('Share File failed: $error\n$stackTrace');
      }),
    );
  }

  static void shareText(String text) {
    s.SharePlus.instance.share(s.ShareParams(text: text));
  }
}

String bytesToReadableString(int bytes) {
  if (bytes < 1024) {
    return "$bytes B";
  } else if (bytes < 1024 * 1024) {
    return "${(bytes / 1024).toStringAsFixed(2)} KB";
  } else if (bytes < 1024 * 1024 * 1024) {
    return "${(bytes / 1024 / 1024).toStringAsFixed(2)} MB";
  } else {
    return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }
}

class FileSelectResult {
  final String path;

  static final _finalizer = Finalizer<String>((path) {
    if (isPathInsideDirectory(path, App.cachePath)) {
      File(path).deleteIgnoreError();
    }
  });

  FileSelectResult(this.path) {
    _finalizer.attach(this, path);
  }

  Future<void> saveTo(String path) async {
    await File(this.path).copy(path);
  }

  Future<Uint8List> readAsBytes() {
    return File(path).readAsBytes();
  }

  String get name => File(path).name;
}
