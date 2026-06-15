import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/comic_details_repository.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

final Map<String, Future<String>> _historyCoverLoads =
    <String, Future<String>>{};

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        final coverFile = localComic.coverFile;
        try {
          if (await coverFile.exists()) {
            final data = await coverFile.readAsBytes();
            if (data.isNotEmpty) {
              return data;
            }
          }
        } catch (_) {
          // Fall back to the remote cover path below.
        }
      }
      url = await _loadHistoryCoverUrl(history);
      checkStop();
      history.cover = url;
    }
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.sourceKey,
      history.id,
      ThumbnailLoadPriority.foregroundVisible,
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
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "history${history.id}${history.sourceKey}";
}

Future<String> _loadHistoryCoverUrl(History history) {
  final key = '${history.sourceKey}@${history.id}';
  final existing = _historyCoverLoads[key];
  if (existing != null) {
    return existing;
  }
  final future = () async {
    final comic = await ComicDetailsRepository().load(
      history.sourceKey,
      history.id,
    );
    if (comic.error) {
      throw comic.errorMessage ?? "Comic source not found.";
    }
    HistoryManager().updateExistingHistoryMetadata(comic.data);
    return comic.data.cover;
  }();
  _historyCoverLoads[key] = future;
  return future.whenComplete(() {
    if (_historyCoverLoads[key] == future) {
      _historyCoverLoads.remove(key);
    }
  });
}
