import 'dart:async';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/utils/ext.dart';

@visibleForTesting
String normalizeDownloadSavePath(String savePath, {bool? windows}) {
  final normalized = File(savePath).absolute.path;
  return (windows ?? Platform.isWindows)
      ? normalized.toLowerCase()
      : normalized;
}

class FileDownloader {
  static final Set<String> _activeSavePaths = {};

  final String url;
  final String savePath;
  final int maxConcurrent;

  FileDownloader(this.url, this.savePath, {this.maxConcurrent = 4});

  int _currentBytes = 0;

  int _lastBytes = 0;

  late int _fileSize;

  final _dio = Dio();

  final Set<CancelToken> _cancelTokens = {};

  RandomAccessFile? _file;

  Future<void> _writeQueue = Future.value();

  Future<void>? _closeFileFuture;

  int _kChunkSize = 16 * 1024 * 1024;

  bool _canceled = false;

  String? _activeRegistryKey;

  @visibleForTesting
  bool get debugIsCanceled => _canceled;

  @visibleForTesting
  static bool debugIsSavePathActive(String savePath) {
    return _activeSavePaths.contains(normalizeDownloadSavePath(savePath));
  }

  Timer? _statusTimer;

  late List<_DownloadBlock> _blocks;

  Future<void> _writeStatus() async {
    var file = File("$savePath.download");
    await file.writeAsString(_blocks.map((e) => e.toString()).join("\n"));
  }

  Future<bool> _readStatus() async {
    var file = File("$savePath.download");
    if (!await file.exists()) {
      return false;
    }

    var lines = await file.readAsLines();
    final blocks = _parseDownloadStatusBlocks(lines, _fileSize);
    if (blocks == null) {
      Log.warning(
        "Invalid download status",
        "Discarding corrupted resume state for $savePath",
      );
      await file.delete();
      return false;
    }
    _blocks = blocks;
    return true;
  }

  /// create file and write empty bytes
  Future<void> _prepareFile() async {
    var file = File(savePath);
    if (await file.exists()) {
      if (file.lengthSync() == _fileSize &&
          File("$savePath.download").existsSync()) {
        _file = await file.open(mode: FileMode.append);
        return;
      } else {
        await file.delete();
      }
    }

    await file.create(recursive: true);
    _file = await file.open(mode: FileMode.append);
    await _file!.truncate(_fileSize);
  }

  Future<void> _createTasks() async {
    final cancelToken = _createCancelToken();
    Response<dynamic> res;
    try {
      res = await _dio.head(url, cancelToken: cancelToken);
    } finally {
      _cancelTokens.remove(cancelToken);
    }
    var length = res.headers["content-length"]?.first;
    final parsedLength = parseDownloadContentLength(length);
    if (parsedLength == null) {
      throw Exception("Invalid content-length for $url: $length");
    }
    _fileSize = parsedLength;

    await _prepareFile();

    if (await _readStatus()) {
      _currentBytes = _blocks.fold<int>(
        0,
        (previousValue, element) => previousValue + element.downloadedBytes,
      );
    } else {
      _blocks = _buildDownloadBlocks(_fileSize);
    }
  }

  List<_DownloadBlock> _buildDownloadBlocks(int fileSize) {
    if (fileSize > 1024 * 1024 * 1024) {
      _kChunkSize = 64 * 1024 * 1024;
    } else if (fileSize > 512 * 1024 * 1024) {
      _kChunkSize = 32 * 1024 * 1024;
    }

    final blocks = <_DownloadBlock>[];
    for (var i = 0; i < fileSize; i += _kChunkSize) {
      var end = i + _kChunkSize;
      if (end > fileSize) {
        blocks.add(_DownloadBlock(i, fileSize, 0, false));
      } else {
        blocks.add(_DownloadBlock(i, i + _kChunkSize, 0, false));
      }
    }
    return blocks;
  }

  Stream<DownloadingStatus> start() {
    late StreamController<DownloadingStatus> stream;
    stream = StreamController<DownloadingStatus>(
      onCancel: () async {
        await stop();
      },
    );
    if (!_tryRegisterSavePath()) {
      scheduleMicrotask(() async {
        if (!stream.isClosed) {
          stream.addError(
            StateError("A download is already active for $savePath"),
          );
          await stream.close();
        }
      });
      return stream.stream;
    }
    _download(stream);
    return stream.stream;
  }

  bool _tryRegisterSavePath() {
    final registryKey = normalizeDownloadSavePath(savePath);
    if (_activeSavePaths.contains(registryKey)) {
      return false;
    }
    _activeSavePaths.add(registryKey);
    _activeRegistryKey = registryKey;
    return true;
  }

  void _releaseSavePath() {
    final registryKey = _activeRegistryKey;
    if (registryKey == null) {
      return;
    }
    _activeSavePaths.remove(registryKey);
    _activeRegistryKey = null;
  }

  void _reportStatus(StreamController<DownloadingStatus> stream) {
    if (stream.isClosed) return;
    stream.add(DownloadingStatus(_currentBytes, _fileSize, 0));
  }

  Future<void> _enqueueFileWrite(Future<void> Function() write) {
    final next = _writeQueue.then((_) => write());
    _writeQueue = next.catchError((_) {});
    return next;
  }

  Future<void> _flushBlockBuffer(_DownloadBlock block, List<int> buffer) async {
    if (buffer.isEmpty) return;
    final bytes = List<int>.from(buffer);
    buffer.clear();
    await _enqueueFileWrite(() async {
      final file = _file;
      if (_canceled || file == null) return;
      await file.setPosition(block.start + block.downloadedBytes);
      await file.writeFrom(bytes);
      block.downloadedBytes += bytes.length;
      _currentBytes += bytes.length;
      await _writeStatus();
    });
  }

  Future<void> _closeFile() async {
    return _closeFileFuture ??= _doCloseFile();
  }

  Future<void> _doCloseFile() async {
    _statusTimer?.cancel();
    _statusTimer = null;
    try {
      await _writeQueue;
    } catch (_) {
      // The originating download future reports write errors.
    }
    final file = _file;
    _file = null;
    try {
      await file?.close();
    } on FileSystemException {
      // stop() and the download task can race to close the same file.
    }
  }

  CancelToken _createCancelToken() {
    final token = CancelToken();
    if (_canceled) {
      token.cancel('download cancelled');
      return token;
    }
    _cancelTokens.add(token);
    return token;
  }

  void _cancelNetworkRequests() {
    final tokens = _cancelTokens.toList(growable: false);
    _cancelTokens.clear();
    for (final token in tokens) {
      if (!token.isCancelled) {
        token.cancel('download cancelled');
      }
    }
  }

  void _download(StreamController<DownloadingStatus> resultStream) async {
    try {
      var proxy = await getProxy();
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          return HttpClient()
            ..findProxy = (uri) => proxy == null ? "DIRECT" : "PROXY $proxy";
        },
      );

      // get file size
      await _createTasks();

      if (_canceled) {
        await _closeFile();
        await resultStream.close();
        return;
      }

      // check if file is downloaded
      if (_currentBytes >= _fileSize) {
        await _closeFile();
        final statusFile = File("$savePath.download");
        if (await statusFile.exists()) {
          await statusFile.delete();
        }
        resultStream.add(DownloadingStatus(_currentBytes, _fileSize, 0, true));
        await resultStream.close();
        return;
      }

      _reportStatus(resultStream);

      _statusTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_canceled || _currentBytes >= _fileSize) {
          timer.cancel();
          if (_statusTimer == timer) {
            _statusTimer = null;
          }
          return;
        }
        if (!resultStream.isClosed) {
          resultStream.add(
            DownloadingStatus(
              _currentBytes,
              _fileSize,
              _currentBytes - _lastBytes,
            ),
          );
        }
        _lastBytes = _currentBytes;
      });

      // start downloading
      await _scheduleDownload();
      if (_canceled) {
        await _closeFile();
        await resultStream.close();
        return;
      }
      await _closeFile();
      final statusFile = File("$savePath.download");
      if (await statusFile.exists()) {
        await statusFile.delete();
      }

      // check if download is finished
      if (_currentBytes < _fileSize) {
        resultStream.addError(
          Exception(
            "Download failed: Expected $_fileSize bytes, "
            "but only $_currentBytes bytes downloaded.",
          ),
        );
        await resultStream.close();
        return;
      }

      resultStream.add(DownloadingStatus(_currentBytes, _fileSize, 0, true));
      await resultStream.close();
    } catch (e, s) {
      _canceled = true;
      _cancelNetworkRequests();
      await _closeFile();
      if (e is DioException && CancelToken.isCancel(e)) {
        if (!resultStream.isClosed) {
          await resultStream.close();
        }
        return;
      }
      if (!resultStream.isClosed) {
        resultStream.addError(e, s);
        await resultStream.close();
      }
    } finally {
      _releaseSavePath();
    }
  }

  Future<void> _scheduleDownload() async {
    final concurrency = maxConcurrent < 1 ? 1 : maxConcurrent;
    final workerCount = _blocks.length < concurrency
        ? _blocks.length
        : concurrency;
    if (workerCount == 0) return;

    Future<void> worker() async {
      while (true) {
        if (_canceled) return;
        final block = _blocks.firstWhereOrNull(
          (element) =>
              !element.downloading &&
              element.end - element.start > element.downloadedBytes,
        );
        if (block == null) {
          break;
        }
        block.downloading = true;
        try {
          await _fetchBlock(block);
        } catch (_) {
          _canceled = true;
          rethrow;
        }
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<void> _fetchBlock(_DownloadBlock block) async {
    final start = block.start;
    final end = block.end;
    final requestStart = start + block.downloadedBytes;

    if (start > _fileSize) {
      return;
    }

    var options = Options(
      responseType: ResponseType.stream,
      headers: {
        "Range": "bytes=$requestStart-${end - 1}",
        "Accept": "*/*",
        "Accept-Encoding": "identity",
      },
      preserveHeaderCase: true,
    );
    final cancelToken = _createCancelToken();
    try {
      var res = await _dio.get<ResponseBody>(
        url,
        options: options,
        cancelToken: cancelToken,
      );
      if (_canceled) return;
      final body = res.data;
      if (body == null) {
        throw Exception("Failed to download block $start-$end: empty response");
      }
      if (!shouldAcceptDownloadResponseStatus(
        statusCode: res.statusCode,
        requestStart: requestStart,
        blockStart: block.start,
        blockEnd: block.end,
        fileSize: _fileSize,
      )) {
        throw Exception(
          "Unexpected response status ${res.statusCode} for range "
          "$requestStart-${end - 1}",
        );
      }

      var buffer = <int>[];
      await for (var data in body.stream) {
        if (_canceled) return;
        final acceptedLength = acceptedDownloadChunkLength(
          data.length,
          remainingBlockBytes: block.end - block.start - block.downloadedBytes,
          pendingBufferBytes: buffer.length,
        );
        if (acceptedLength == null) {
          throw Exception(
            "Received more bytes than expected for block $start-$end",
          );
        }
        buffer.addAll(data);
        if (buffer.length > 256 * 1024) {
          await _flushBlockBuffer(block, buffer);
        }
      }

      if (buffer.isNotEmpty) {
        await _flushBlockBuffer(block, buffer);
      }
    } finally {
      _cancelTokens.remove(cancelToken);
      block.downloading = false;
    }
  }

  Future<void> stop() async {
    _canceled = true;
    _cancelNetworkRequests();
    await _closeFile();
  }
}

@visibleForTesting
bool shouldAcceptDownloadResponseStatus({
  required int? statusCode,
  required int requestStart,
  required int blockStart,
  required int blockEnd,
  required int fileSize,
}) {
  if (statusCode == HttpStatus.partialContent) {
    return true;
  }
  if (statusCode != HttpStatus.ok) {
    return false;
  }
  return requestStart == 0 && blockStart == 0 && blockEnd == fileSize;
}

@visibleForTesting
int? acceptedDownloadChunkLength(
  int chunkLength, {
  required int remainingBlockBytes,
  int pendingBufferBytes = 0,
}) {
  if (chunkLength < 0 || remainingBlockBytes < 0 || pendingBufferBytes < 0) {
    return null;
  }
  if (pendingBufferBytes > remainingBlockBytes) {
    return null;
  }
  if (chunkLength > remainingBlockBytes - pendingBufferBytes) {
    return null;
  }
  return chunkLength;
}

class DownloadingStatus {
  /// The current downloaded bytes
  final int downloadedBytes;

  /// The total bytes of the file
  final int totalBytes;

  /// Whether the download is finished
  final bool isFinished;

  /// The download speed in bytes per second
  final int bytesPerSecond;

  const DownloadingStatus(
    this.downloadedBytes,
    this.totalBytes,
    this.bytesPerSecond, [
    this.isFinished = false,
  ]);

  @override
  String toString() {
    return "Downloaded: $downloadedBytes/$totalBytes ${isFinished ? "Finished" : ""}";
  }
}

class _DownloadBlock {
  final int start;
  final int end;
  int downloadedBytes;
  bool downloading;

  _DownloadBlock(this.start, this.end, this.downloadedBytes, this.downloading);

  @override
  String toString() {
    return "$start-$end-$downloadedBytes";
  }

  static _DownloadBlock? tryParse(String str) {
    final parts = str.trim().split("-");
    if (parts.length != 3) {
      return null;
    }
    final start = int.tryParse(parts[0]);
    final end = int.tryParse(parts[1]);
    final downloadedBytes = int.tryParse(parts[2]);
    if (start == null || end == null || downloadedBytes == null) {
      return null;
    }
    return _DownloadBlock(start, end, downloadedBytes, false);
  }
}

List<_DownloadBlock>? _parseDownloadStatusBlocks(
  Iterable<String> lines,
  int fileSize,
) {
  if (fileSize < 0) return null;

  final normalizedLines = lines
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  if (fileSize == 0) {
    return normalizedLines.isEmpty ? <_DownloadBlock>[] : null;
  }

  final blocks = <_DownloadBlock>[];
  for (final line in normalizedLines) {
    final block = _DownloadBlock.tryParse(line);
    if (block == null) {
      return null;
    }
    blocks.add(block);
  }
  if (blocks.isEmpty) return null;

  blocks.sort((a, b) => a.start.compareTo(b.start));
  var cursor = 0;
  for (final block in blocks) {
    final blockLength = block.end - block.start;
    if (block.start != cursor ||
        block.end <= block.start ||
        block.end > fileSize ||
        block.downloadedBytes < 0 ||
        block.downloadedBytes > blockLength) {
      return null;
    }
    cursor = block.end;
  }
  return cursor == fileSize ? blocks : null;
}

@visibleForTesting
int? parseDownloadStatusCurrentBytes(
  Iterable<String> lines, {
  required int fileSize,
}) {
  final blocks = _parseDownloadStatusBlocks(lines, fileSize);
  if (blocks == null) return null;
  return blocks.fold<int>(
    0,
    (previousValue, element) => previousValue + element.downloadedBytes,
  );
}

@visibleForTesting
int? parseDownloadContentLength(String? value) {
  if (value == null) {
    return null;
  }
  final parsed = int.tryParse(value.trim());
  if (parsed == null || parsed < 0) {
    return null;
  }
  return parsed;
}
