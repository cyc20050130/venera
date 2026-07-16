import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_7zip/flutter_7zip.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:uuid/uuid.dart';
import 'package:zip_flutter/zip_flutter.dart';

const _supportedCbzImageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'jpe',
};

@visibleForTesting
bool isSupportedCbzImageExtension(String extension) {
  final normalized = extension.startsWith('.')
      ? extension.substring(1)
      : extension;
  return _supportedCbzImageExtensions.contains(normalized.toLowerCase());
}

typedef ComicArchiveEntry = ({String name, int size, bool isDirectory});

@visibleForTesting
String normalizeComicArchiveEntryName(String value) {
  if (value.isEmpty || value.contains('\u0000')) {
    throw const FormatException('Empty archive entry path');
  }
  final normalized = value.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    throw FormatException('Absolute archive entry path: $value');
  }
  final segments = normalized.split('/');
  if (segments.any((segment) => segment == '..')) {
    throw FormatException('Archive entry escapes destination: $value');
  }
  final clean = segments
      .where((segment) => segment.isNotEmpty && segment != '.')
      .toList(growable: false);
  if (clean.isEmpty) {
    throw FormatException('Empty archive entry path: $value');
  }
  return clean.join('/');
}

@visibleForTesting
void validateComicArchiveEntries(
  Iterable<ComicArchiveEntry> entries, {
  required int archiveBytes,
  int maxEntries = 100000,
  int maxEntryBytes = 2 * 1024 * 1024 * 1024,
  int maxExpandedBytes = 20 * 1024 * 1024 * 1024,
  int maxCompressionRatio = 200,
  int compressionRatioSlackBytes = 64 * 1024 * 1024,
}) {
  if (archiveBytes < 0) {
    throw const FormatException('Invalid archive size');
  }
  final seen = <String>{};
  var count = 0;
  var expandedBytes = 0;
  for (final entry in entries) {
    count++;
    if (count > maxEntries) {
      throw const FormatException('Archive contains too many entries');
    }
    final name = normalizeComicArchiveEntryName(entry.name);
    if (!seen.add(name.toLowerCase())) {
      throw FormatException('Duplicate archive entry: $name');
    }
    if (entry.size < 0 || entry.size > maxEntryBytes) {
      throw FormatException('Archive entry is too large: $name');
    }
    if (!entry.isDirectory) {
      expandedBytes += entry.size;
      if (expandedBytes > maxExpandedBytes) {
        throw const FormatException('Archive expands beyond the size limit');
      }
    }
  }
  final ratioLimit =
      archiveBytes * maxCompressionRatio + compressionRatioSlackBytes;
  if (expandedBytes > ratioLimit) {
    throw const FormatException('Archive compression ratio is unsafe');
  }
}

class ComicMetaData {
  final String title;

  final String author;

  final List<String> tags;

  final List<ComicChapter>? chapters;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'tags': tags,
    'chapters': chapters?.map((e) => e.toJson()).toList(),
  };

  ComicMetaData.fromJson(Map<String, dynamic> json)
    : title = _cbzString(json['title']),
      author = _cbzString(json['author']),
      tags = _cbzStringList(json['tags']),
      chapters = _cbzChapters(json['chapters']);

  ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.chapters,
  });
}

class ComicChapter {
  final String title;

  final int start;

  final int end;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};

  ComicChapter.fromJson(Map<String, dynamic> json)
    : title = _cbzString(json['title']),
      start = _cbzInt(json['start']),
      end = _cbzInt(json['end']);

  ComicChapter({required this.title, required this.start, required this.end});
}

String _cbzString(Object? value) {
  return value?.toString() ?? '';
}

int _cbzInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

List<String> _cbzStringList(Object? value) {
  if (value is! Iterable) {
    return <String>[];
  }
  return value
      .where((element) => element != null)
      .map((element) => element.toString())
      .where((element) => element.isNotEmpty)
      .toList();
}

List<ComicChapter>? _cbzChapters(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! Iterable) {
    return const <ComicChapter>[];
  }
  return value
      .whereType<Map>()
      .map(
        (chapter) => ComicChapter.fromJson(
          chapter.map((key, value) => MapEntry(key.toString(), value)),
        ),
      )
      .toList();
}

@visibleForTesting
ComicChapter buildCbzExportChapterMetadata({
  required String title,
  required int firstImageNumber,
  required int imageCount,
}) {
  if (firstImageNumber < 1 || imageCount < 1) {
    throw ArgumentError('Invalid CBZ chapter range');
  }
  return ComicChapter(
    title: title,
    start: firstImageNumber,
    end: firstImageNumber + imageCount - 1,
  );
}

@visibleForTesting
Map<String, String> buildCbzImportChapterMap(
  List<ComicChapter> chapters,
  int imageCount,
) {
  final result = <String, String>{};
  for (var i = 0; i < chapters.length; i++) {
    final chapter = chapters[i];
    if (chapter.start < 1 ||
        chapter.end < chapter.start ||
        chapter.end > imageCount) {
      throw ArgumentError('Invalid CBZ chapter range: ${chapter.title}');
    }
    result[i.toString()] = chapter.title;
  }
  return result;
}

@visibleForTesting
String buildCbzImportDirectoryName(String localPath, String title) {
  return findValidDirectoryName(localPath, title);
}

@visibleForTesting
String buildCbzImportCacheDirectory(String cachePath, String operationId) {
  return FilePath.join(cachePath, 'cbz_import-$operationId');
}

@visibleForTesting
String buildCbzExportCacheDirectory(String cachePath, String operationId) {
  return FilePath.join(cachePath, 'cbz_export-$operationId');
}

@visibleForTesting
String buildCbzTemporaryOutputPath(String outputPath, String operationId) {
  final file = File(outputPath);
  return FilePath.join(file.parent.path, '.${file.name}.$operationId.tmp');
}

@visibleForTesting
String buildCbzBackupOutputPath(String outputPath, String operationId) {
  final file = File(outputPath);
  return FilePath.join(file.parent.path, '.${file.name}.$operationId.bak');
}

@visibleForTesting
Future<void> commitCbzTemporaryOutput({
  required File tempFile,
  required File outputFile,
  required File backupFile,
}) async {
  await commitTemporaryOutputFile(
    tempFile: tempFile,
    outputFile: outputFile,
    backupFile: backupFile,
  );
}

/// Comic Book Archive. Currently supports CBZ, ZIP and 7Z formats.
abstract class CBZ {
  static Future<FileType> checkType(File file) async {
    var header = <int>[];
    await for (var bytes in file.openRead()) {
      header.addAll(bytes);
      if (header.length >= 32) break;
    }
    return detectFileType(header);
  }

  static Future<void> extractArchive(File file, Directory out) async {
    var fileType = await checkType(file);
    if (fileType.mime == 'application/zip') {
      await Isolate.run(() {
        final archive = ZipFile.openRead(file.path);
        try {
          validateComicArchiveEntries(
            archive.getAllEntries().map(
              (entry) => (
                name: entry.name,
                size: entry.size,
                isDirectory: entry.isDir,
              ),
            ),
            archiveBytes: file.lengthSync(),
          );
        } finally {
          archive.close();
        }
      });
      await ZipFile.openAndExtractAsync(file.path, out.path, 4);
    } else if (fileType.mime == "application/x-7z-compressed") {
      await Isolate.run(() {
        final archive = SZArchive.open(file.path);
        try {
          final entries = <ComicArchiveEntry>[];
          for (var index = 0; index < archive.numFiles; index++) {
            final entry = archive.getFile(index);
            entries.add((
              name: entry.name,
              size: entry.size,
              isDirectory: entry.isDirectory,
            ));
          }
          validateComicArchiveEntries(entries, archiveBytes: file.lengthSync());
        } finally {
          archive.dispose();
        }
      });
      await SZArchive.extractIsolates(file.path, out.path, 4);
    } else {
      throw Exception('Unsupported archive type');
    }
    final outputRoot = p.normalize(p.absolute(out.path));
    await for (final entity in out.list(recursive: true, followLinks: false)) {
      final entityPath = p.normalize(p.absolute(entity.path));
      if (!p.isWithin(outputRoot, entityPath)) {
        throw const FormatException('Archive entry escapes destination');
      }
      if (entity is Link) {
        throw FormatException('Archive contains a link: ${entity.path}');
      }
    }
  }

  static Future<LocalComic> import(File file) async {
    final operationId = const Uuid().v4();
    final cacheRoot = Directory(
      buildCbzImportCacheDirectory(App.cachePath, operationId),
    );
    Directory? destinationToCleanup;
    var imported = false;
    await cacheRoot.deleteIgnoreError(recursive: true);
    cacheRoot.createSync();
    try {
      var cache = cacheRoot;
      await extractArchive(file, cache);
      var f = cache.listSync();
      if (f.length == 1 && f.first is Directory) {
        cache = f.first as Directory;
      }
      var metaDataFile = File(FilePath.join(cache.path, 'metadata.json'));
      ComicMetaData? metaData;
      if (metaDataFile.existsSync()) {
        try {
          metaData = ComicMetaData.fromJson(
            jsonDecode(metaDataFile.readAsStringSync()),
          );
        } catch (_) {}
      }
      metaData ??= ComicMetaData(
        title: file.basenameWithoutExt,
        author: "",
        tags: [],
      );
      var old = LocalManager().findByName(metaData.title);
      if (old != null) {
        throw Exception('Comic with name ${metaData.title} already exists');
      }
      var files = cache.listSync().whereType<File>().toList();
      files.removeWhere((e) {
        return !isSupportedCbzImageExtension(e.extension);
      });
      if (files.isEmpty) {
        throw Exception('No images found in the archive');
      }
      files.sort((a, b) {
        var aName = a.basenameWithoutExt;
        var bName = b.basenameWithoutExt;
        var aIndex = int.tryParse(aName);
        var bIndex = int.tryParse(bName);
        if (aIndex != null && bIndex != null) {
          return aIndex.compareTo(bIndex);
        } else {
          return a.path.compareTo(b.path);
        }
      });
      var coverFile = files.firstWhereOrNull(
        (element) => element.basenameWithoutExt.toLowerCase() == 'cover',
      );
      if (coverFile != null) {
        files.remove(coverFile);
      } else {
        coverFile = files.first;
      }
      Map<String, String>? cpMap;
      final directoryName = buildCbzImportDirectoryName(
        LocalManager().path,
        metaData.title,
      );
      var dest = Directory(FilePath.join(LocalManager().path, directoryName));
      destinationToCleanup = dest;
      dest.createSync();
      await coverFile.copyMem(
        FilePath.join(dest.path, 'cover.${coverFile.extension}'),
      );
      if (metaData.chapters == null) {
        for (var i = 0; i < files.length; i++) {
          var src = files[i];
          var dst = File(
            FilePath.join(dest.path, '${i + 1}.${src.path.split('.').last}'),
          );
          await src.copyMem(dst.path);
        }
      } else {
        dest.createSync();
        final chapterList = metaData.chapters!;
        cpMap = buildCbzImportChapterMap(chapterList, files.length);
        for (
          var chapterIndex = 0;
          chapterIndex < chapterList.length;
          chapterIndex++
        ) {
          final chapter = chapterList[chapterIndex];
          final chapterFiles = files.sublist(chapter.start - 1, chapter.end);
          var chapterDir = Directory(
            FilePath.join(dest.path, chapterIndex.toString()),
          );
          chapterDir.createSync();
          for (var i = 0; i < chapterFiles.length; i++) {
            var src = chapterFiles[i];
            var dst = File(
              FilePath.join(
                chapterDir.path,
                '${i + 1}.${src.path.split('.').last}',
              ),
            );
            await src.copyMem(dst.path);
          }
        }
      }
      var comic = LocalComic(
        id: LocalManager().findValidId(ComicType.local),
        title: metaData.title,
        subtitle: metaData.author,
        tags: metaData.tags,
        comicType: ComicType.local,
        directory: dest.name,
        chapters: ComicChapters.fromJsonOrNull(cpMap),
        downloadedChapters: cpMap?.keys.toList() ?? [],
        cover: 'cover.${coverFile.extension}',
        createdAt: DateTime.now(),
      );
      imported = true;
      return comic;
    } finally {
      await cacheRoot.deleteIgnoreError(recursive: true);
      if (!imported) {
        await destinationToCleanup?.deleteIgnoreError(recursive: true);
      }
    }
  }

  static Future<File> export(LocalComic comic, String outFilePath) async {
    final operationId = const Uuid().v4();
    var cache = Directory(
      buildCbzExportCacheDirectory(App.cachePath, operationId),
    );
    await cache.deleteIgnoreError(recursive: true);
    cache.createSync();
    final cbz = File(outFilePath);
    final tempCbz = File(buildCbzTemporaryOutputPath(outFilePath, operationId));
    final backupCbz = File(buildCbzBackupOutputPath(outFilePath, operationId));
    await tempCbz.deleteIgnoreError();
    await backupCbz.deleteIgnoreError();
    try {
      List<ComicChapter>? chapters;
      if (comic.chapters == null) {
        var images = await LocalManager().getImages(
          comic.id,
          comic.comicType,
          1,
        );
        int i = 1;
        for (var image in images) {
          var src = File(localFilePathFromUri(image));
          var width = images.length.toString().length;
          var dstName = '${i.toString().padLeft(width, '0')}.${src.extension}';
          var dst = File(FilePath.join(cache.path, dstName));
          await src.copyMem(dst.path);
          i++;
        }
      } else {
        chapters = [];
        var allImages = <String>[];
        for (var c in comic.downloadedChapters) {
          var chapterName = comic.chapters![c];
          var images = await LocalManager().getImages(
            comic.id,
            comic.comicType,
            c,
          );
          if (images.isEmpty) {
            continue;
          }
          var chapter = buildCbzExportChapterMetadata(
            title: chapterName ?? c,
            firstImageNumber: allImages.length + 1,
            imageCount: images.length,
          );
          chapters.add(chapter);
          allImages.addAll(images);
        }
        int i = 1;
        for (var image in allImages) {
          var src = File(localFilePathFromUri(image));
          var width = allImages.length.toString().length;
          var dstName = '${i.toString().padLeft(width, '0')}.${src.extension}';
          var dst = File(FilePath.join(cache.path, dstName));
          await src.copyMem(dst.path);
          i++;
        }
      }
      var cover = comic.coverFile;
      await cover.copyMem(
        FilePath.join(cache.path, 'cover.${cover.path.split('.').last}'),
      );
      final metaData = ComicMetaData(
        title: comic.title,
        author: comic.subtitle,
        tags: comic.tags,
        chapters: chapters,
      );
      await File(
        FilePath.join(cache.path, 'metadata.json'),
      ).writeAsString(jsonEncode(metaData));
      await File(
        FilePath.join(cache.path, 'ComicInfo.xml'),
      ).writeAsString(_buildComicInfoXml(metaData));
      await _compress(cache.path, tempCbz.path);
      await commitCbzTemporaryOutput(
        tempFile: tempCbz,
        outputFile: cbz,
        backupFile: backupCbz,
      );
      return cbz;
    } finally {
      await cache.deleteIgnoreError(recursive: true);
      await tempCbz.deleteIgnoreError();
      await backupCbz.deleteIgnoreError();
    }
  }

  static String _buildComicInfoXml(ComicMetaData data) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buffer.writeln(
      '<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    );

    buffer.writeln('  <Title>${_escapeXml(data.title)}</Title>');
    buffer.writeln('  <Series>${_escapeXml(data.title)}</Series>');

    if (data.author.isNotEmpty) {
      buffer.writeln('  <Writer>${_escapeXml(data.author)}</Writer>');
    }

    if (data.tags.isNotEmpty) {
      var tags = data.tags;
      if (tags.length > 5) {
        tags = tags.sublist(0, 5);
      }
      buffer.writeln('  <Genre>${_escapeXml(tags.join(', '))}</Genre>');
    }

    if (data.chapters != null && data.chapters!.isNotEmpty) {
      final chaptersInfo = data.chapters!
          .map(
            (chapter) =>
                '${_escapeXml(chapter.title)}: ${chapter.start}-${chapter.end}',
          )
          .join('; ');
      buffer.writeln('  <Notes>Chapters: $chaptersInfo</Notes>');
    }

    buffer.writeln('  <Manga>Unknown</Manga>');
    buffer.writeln('  <BlackAndWhite>Unknown</BlackAndWhite>');

    final now = DateTime.now();
    buffer.writeln('  <Year>${now.year}</Year>');

    buffer.writeln('</ComicInfo>');
    return buffer.toString();
  }

  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static _compress(String src, String dst) async {
    await ZipFile.compressFolderAsync(src, dst, 4);
  }
}
