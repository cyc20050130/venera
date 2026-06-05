import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/file_downloader.dart';

void main() {
  test('download status parser restores valid contiguous blocks', () {
    expect(
      parseDownloadStatusCurrentBytes([
        '512-1024-128',
        '0-512-512',
      ], fileSize: 1024),
      640,
    );
  });

  test('download status parser accepts empty zero length files', () {
    expect(parseDownloadStatusCurrentBytes([], fileSize: 0), 0);
    expect(parseDownloadStatusCurrentBytes(['0-1-0'], fileSize: 0), isNull);
  });

  test('download status parser rejects corrupted resume state', () {
    expect(parseDownloadStatusCurrentBytes(['0-512'], fileSize: 1024), isNull);
    expect(
      parseDownloadStatusCurrentBytes(['0-512-bad'], fileSize: 1024),
      isNull,
    );
    expect(
      parseDownloadStatusCurrentBytes(['0-512-600'], fileSize: 1024),
      isNull,
    );
    expect(
      parseDownloadStatusCurrentBytes([
        '0-256-0',
        '512-1024-0',
      ], fileSize: 1024),
      isNull,
    );
    expect(
      parseDownloadStatusCurrentBytes([
        '0-512-0',
        '256-1024-0',
      ], fileSize: 1024),
      isNull,
    );
    expect(
      parseDownloadStatusCurrentBytes(['0-2048-0'], fileSize: 1024),
      isNull,
    );
  });

  test('download content length parser rejects missing or invalid values', () {
    expect(parseDownloadContentLength('0'), 0);
    expect(parseDownloadContentLength(' 1024 '), 1024);
    expect(parseDownloadContentLength(null), isNull);
    expect(parseDownloadContentLength(''), isNull);
    expect(parseDownloadContentLength('-1'), isNull);
    expect(parseDownloadContentLength('bad'), isNull);
  });

  test('range response status validation rejects ignored partial requests', () {
    expect(
      shouldAcceptDownloadResponseStatus(
        statusCode: 206,
        requestStart: 512,
        blockStart: 0,
        blockEnd: 1024,
        fileSize: 2048,
      ),
      isTrue,
    );
    expect(
      shouldAcceptDownloadResponseStatus(
        statusCode: 200,
        requestStart: 0,
        blockStart: 0,
        blockEnd: 2048,
        fileSize: 2048,
      ),
      isTrue,
    );
    expect(
      shouldAcceptDownloadResponseStatus(
        statusCode: 200,
        requestStart: 0,
        blockStart: 0,
        blockEnd: 1024,
        fileSize: 2048,
      ),
      isFalse,
    );
    expect(
      shouldAcceptDownloadResponseStatus(
        statusCode: 200,
        requestStart: 512,
        blockStart: 0,
        blockEnd: 2048,
        fileSize: 2048,
      ),
      isFalse,
    );
  });

  test('download chunk validation rejects writes past a block boundary', () {
    expect(acceptedDownloadChunkLength(128, remainingBlockBytes: 512), 128);
    expect(acceptedDownloadChunkLength(512, remainingBlockBytes: 512), 512);
    expect(acceptedDownloadChunkLength(513, remainingBlockBytes: 512), isNull);
    expect(acceptedDownloadChunkLength(1, remainingBlockBytes: -1), isNull);
    expect(
      acceptedDownloadChunkLength(
        128,
        remainingBlockBytes: 512,
        pendingBufferBytes: 384,
      ),
      128,
    );
    expect(
      acceptedDownloadChunkLength(
        129,
        remainingBlockBytes: 512,
        pendingBufferBytes: 384,
      ),
      isNull,
    );
    expect(
      acceptedDownloadChunkLength(
        1,
        remainingBlockBytes: 512,
        pendingBufferBytes: 513,
      ),
      isNull,
    );
  });

  test('download stream cancellation stops active work quietly', () async {
    final previousProxy = appdata.settings['proxy'];
    appdata.settings['proxy'] = 'direct';
    addTearDown(() {
      appdata.settings['proxy'] = previousProxy;
    });

    final tempDir = await Directory.systemTemp.createTemp(
      'venera-downloader-cancel-',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final firstGetStarted = Completer<void>();
    final releaseGet = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      if (!releaseGet.isCompleted) {
        releaseGet.complete();
      }
      await server.close(force: true);
    });

    unawaited(
      server.forEach((request) async {
        if (request.method == 'HEAD') {
          request.response.contentLength = 1024;
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers
            ..set(HttpHeaders.acceptRangesHeader, 'bytes')
            ..set(HttpHeaders.contentRangeHeader, 'bytes 0-1023/1024');
          request.response.contentLength = 1024;
          if (!firstGetStarted.isCompleted) {
            firstGetStarted.complete();
          }
          await releaseGet.future;
          request.response.add(List<int>.filled(1024, 1));
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
      }),
    );

    final downloader = FileDownloader(
      'http://${server.address.host}:${server.port}/file.bin',
      '${tempDir.path}${Platform.pathSeparator}file.bin',
      maxConcurrent: 1,
    );
    final errors = <Object>[];
    late StreamSubscription<DownloadingStatus> subscription;
    subscription = downloader.start().listen((_) {}, onError: errors.add);

    await firstGetStarted.future.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    if (!releaseGet.isCompleted) {
      releaseGet.complete();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(downloader.debugIsCanceled, isTrue);
    expect(errors, isEmpty);
  });

  test(
    'duplicate active downloads for the same save path are rejected',
    () async {
      final previousProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      addTearDown(() {
        appdata.settings['proxy'] = previousProxy;
      });

      final tempDir = await Directory.systemTemp.createTemp(
        'venera-downloader-duplicate-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final firstGetStarted = Completer<void>();
      final releaseGet = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        if (!releaseGet.isCompleted) {
          releaseGet.complete();
        }
        await server.close(force: true);
      });

      unawaited(
        server.forEach((request) async {
          if (request.method == 'HEAD') {
            request.response.contentLength = 1024;
            await request.response.close();
            return;
          }
          if (request.method == 'GET') {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers
              ..set(HttpHeaders.acceptRangesHeader, 'bytes')
              ..set(HttpHeaders.contentRangeHeader, 'bytes 0-1023/1024');
            request.response.contentLength = 1024;
            if (!firstGetStarted.isCompleted) {
              firstGetStarted.complete();
            }
            await releaseGet.future;
            request.response.add(List<int>.filled(1024, 1));
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.response.close();
        }),
      );

      final savePath = '${tempDir.path}${Platform.pathSeparator}file.bin';
      final url = 'http://${server.address.host}:${server.port}/file.bin';
      final firstDownloader = FileDownloader(url, savePath, maxConcurrent: 1);
      final firstErrors = <Object>[];
      final firstSubscription = firstDownloader.start().listen(
        (_) {},
        onError: firstErrors.add,
      );

      expect(FileDownloader.debugIsSavePathActive(savePath), isTrue);

      final duplicateErrors = <Object>[];
      final duplicateDone = Completer<void>();
      FileDownloader(url, savePath, maxConcurrent: 1).start().listen(
        (_) {},
        onError: duplicateErrors.add,
        onDone: duplicateDone.complete,
      );

      await duplicateDone.future.timeout(const Duration(seconds: 2));
      expect(duplicateErrors, hasLength(1));
      expect(duplicateErrors.single, isA<StateError>());

      await firstGetStarted.future.timeout(const Duration(seconds: 5));
      await firstSubscription.cancel();
      if (!releaseGet.isCompleted) {
        releaseGet.complete();
      }

      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (FileDownloader.debugIsSavePathActive(savePath)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('download save path registry was not released after cancel');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(firstDownloader.debugIsCanceled, isTrue);
      expect(firstErrors, isEmpty);
    },
  );
}
