import 'dart:async' show Future, StreamController;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'image_favorites_provider.dart' as image_provider;

@visibleForTesting
String imageFavoriteCacheKey(ImageFavorite imageFavorite) {
  return "ImageFavorites ${imageFavorite.imageKey}@${imageFavorite.sourceKey}@${imageFavorite.id}@${imageFavorite.eid}";
}

String _imageFavoriteCacheFileName(ImageFavorite imageFavorite) {
  return md5.convert(imageFavoriteCacheKey(imageFavorite).codeUnits).toString();
}

File _imageFavoriteCacheFile(ImageFavorite imageFavorite) {
  return File(
    FilePath.join(
      App.cachePath,
      'image_favorites',
      _imageFavoriteCacheFileName(imageFavorite),
    ),
  );
}

class ImageFavoritesProvider
    extends BaseImageProvider<image_provider.ImageFavoritesProvider> {
  /// Image provider for imageFavorites
  const ImageFavoritesProvider(this.imageFavorite);

  final ImageFavorite imageFavorite;

  int get page => imageFavorite.page;

  String get sourceKey => imageFavorite.sourceKey;

  String get cid => imageFavorite.id;

  String get eid => imageFavorite.eid;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    var imageKey = imageFavorite.imageKey;
    var localImage = await getImageFromLocal();
    checkStop?.call();
    if (localImage != null) {
      return localImage;
    }
    var cacheImage = await readFromCache();
    checkStop?.call();
    if (cacheImage != null) {
      return cacheImage;
    }
    var gotImageKey = false;
    if (imageKey == "") {
      imageKey = await getImageKey();
      checkStop?.call();
      gotImageKey = true;
    }
    Uint8List image;
    try {
      image = await getImageFromNetwork(imageKey, chunkEvents, checkStop);
    } catch (e) {
      if (gotImageKey) {
        rethrow;
      } else {
        imageKey = await getImageKey();
        image = await getImageFromNetwork(imageKey, chunkEvents, checkStop);
      }
    }
    await writeToCache(image);
    return image;
  }

  Future<void> writeToCache(Uint8List image) async {
    var file = _imageFavoriteCacheFile(imageFavorite);
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    await file.writeAsBytes(image);
  }

  Future<Uint8List?> readFromCache() async {
    var file = _imageFavoriteCacheFile(imageFavorite);
    if (!file.existsSync()) {
      return null;
    }
    final data = await file.readAsBytes();
    return data.isEmpty ? null : data;
  }

  /// Delete a image favorite cache
  static Future<void> deleteFromCache(ImageFavorite imageFavorite) async {
    var file = _imageFavoriteCacheFile(imageFavorite);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  Future<Uint8List?> getImageFromLocal() async {
    final type = ComicType.fromKey(sourceKey);
    var localComic = LocalManager().find(cid, type);
    if (localComic == null) {
      return null;
    }
    final Object localEpisode;
    if (localComic.hasChapters) {
      if (!localComic.downloadedChapters.contains(eid)) {
        return null;
      }
      localEpisode = eid;
    } else {
      localEpisode = 1;
    }
    var images = await LocalManager().getImages(cid, type, localEpisode);
    final imagePath = images.elementAtOrNull(page - 1);
    if (imagePath == null) {
      return null;
    }
    final file = File(localFilePathFromUri(imagePath));
    if (!await file.exists()) {
      return null;
    }
    try {
      final data = await file.readAsBytes();
      return data.isEmpty ? null : data;
    } on FileSystemException {
      return null;
    }
  }

  Future<Uint8List> getImageFromNetwork(
    String imageKey,
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    await for (var progress in ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
    )) {
      checkStop?.call();
      if (chunkEvents != null) {
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: progress.currentBytes,
            expectedTotalBytes: progress.totalBytes,
          ),
        );
      }
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  Future<String> getImageKey() async {
    String sourceKey = imageFavorite.sourceKey;
    String cid = imageFavorite.id;
    String eid = imageFavorite.eid;
    var page = imageFavorite.page;
    var comicSource = ComicSource.find(sourceKey);
    if (comicSource == null) {
      throw "Error: Comic source not found.";
    }
    final loadComicPages = comicSource.loadComicPages;
    if (loadComicPages == null) {
      throw "Error: Comic pages loader not available.";
    }
    var res = await loadComicPages(cid, eid);
    if (res.error) {
      throw "Error: ${res.errorMessage}";
    }
    final index = page - 1;
    if (index < 0 || index >= res.data.length) {
      throw "Error: Image favorite page out of range.";
    }
    return res.data[index];
  }

  @override
  Future<ImageFavoritesProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => imageFavoriteCacheKey(imageFavorite);
}
