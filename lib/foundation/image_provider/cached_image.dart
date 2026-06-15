import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import 'base_image_provider.dart';
import 'cached_image.dart' as image_provider;

class CachedImageProvider
    extends BaseImageProvider<image_provider.CachedImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const CachedImageProvider(
    this.url, {
    this.headers,
    this.sourceKey,
    this.cid,
    this.fallbackToLocalCover = false,
    this.loadPriority = ThumbnailLoadPriority.foregroundVisible,
  });

  final String url;

  final Map<String, String>? headers;

  final String? sourceKey;

  final String? cid;

  // Use local cover if network image fails to load.
  final bool fallbackToLocalCover;

  final ThumbnailLoadPriority loadPriority;

  @visibleForTesting
  static int get debugMaxLoadingCount =>
      ImageDownloader.debugMaxThumbnailLoadingCount;

  @visibleForTesting
  static void debugResetLoadingState() {
    ImageDownloader.debugResetThumbnailLoadingState();
  }

  @visibleForTesting
  static Future<void> debugAcquireLoadingSlot(
    void Function() checkStop, {
    ThumbnailLoadPriority priority = ThumbnailLoadPriority.foregroundVisible,
  }) {
    return ImageDownloader.debugAcquireThumbnailLoadingSlot(
      checkStop,
      priority: priority,
    );
  }

  @visibleForTesting
  static void debugReleaseLoadingSlot({
    ThumbnailLoadPriority priority = ThumbnailLoadPriority.foregroundVisible,
  }) {
    ImageDownloader.debugReleaseThumbnailLoadingSlot(priority: priority);
  }

  @visibleForTesting
  static int get loadingCount => ImageDownloader.thumbnailLoadingCount;

  @visibleForTesting
  static set loadingCount(int value) {
    ImageDownloader.thumbnailLoadingCount = value;
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    try {
      if (url.startsWith("file://")) {
        var file = File(localFilePathFromUri(url));
        return file.readAsBytes();
      }
      await for (var progress in ImageDownloader.loadThumbnail(
        url,
        sourceKey,
        cid,
        loadPriority,
        checkStop,
      )) {
        checkStop();
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: progress.currentBytes,
            expectedTotalBytes: progress.totalBytes,
          ),
        );
        if (progress.imageBytes != null) {
          return progress.imageBytes!;
        }
      }
      throw "Error: Empty response body.";
    } catch (e) {
      if (fallbackToLocalCover && sourceKey != null && cid != null) {
        final localComic = LocalManager().find(
          cid!,
          ComicType.fromKey(sourceKey!),
        );
        if (localComic != null) {
          var file = localComic.coverFile;
          if (await file.exists()) {
            var data = await file.readAsBytes();
            if (data.isNotEmpty) {
              return data;
            }
          }
        }
      }
      rethrow;
    }
  }

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => url + (sourceKey ?? "") + (cid ?? "");
}
