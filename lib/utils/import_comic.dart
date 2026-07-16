import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';
import 'cbz.dart';
import 'io.dart';

const _supportedImportedComicImageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'jpe',
};

const _ehViewerCategoryTags = [
  "MISC",
  "DOUJINSHI",
  "MANGA",
  "ARTISTCG",
  "GAMECG",
  "IMAGE SET",
  "COSPLAY",
  "ASIAN PORN",
  "NON-H",
  "WESTERN",
];

@visibleForTesting
bool isSupportedImportedComicImageExtension(String extension) {
  final normalized = extension.startsWith('.')
      ? extension.substring(1)
      : extension;
  return _supportedImportedComicImageExtensions.contains(
    normalized.toLowerCase(),
  );
}

@visibleForTesting
String buildImportBackupDirectoryPath(Directory destination) {
  final backupName = findValidDirectoryName(
    destination.parent.path,
    '${destination.name}_old',
  );
  return FilePath.join(destination.parent.path, backupName);
}

@visibleForTesting
String? safeEhViewerCategoryTag(Object? category) {
  final value = switch (category) {
    int() => category,
    num() => category.toInt(),
    String() => int.tryParse(category),
    _ => null,
  };
  if (value == null || value <= 0) {
    return null;
  }
  final index = (log(value) / ln2).floor();
  if (index < 0 || index >= _ehViewerCategoryTags.length) {
    return null;
  }
  return _ehViewerCategoryTags[index];
}

class ImportComic {
  final String? selectedFolder;
  final bool copyToLocal;

  const ImportComic({this.selectedFolder, this.copyToLocal = true});

  Future<bool> cbz() async {
    var file = await selectFile(ext: ['cbz', 'zip', '7z', 'cb7']);
    Map<String?, List<LocalComic>> imported = {};
    if (file == null) {
      return false;
    }
    var controller = showLoadingDialog(App.rootContext, allowCancel: false);
    try {
      var comic = await CBZ.import(File(file.path));
      imported[selectedFolder] = [comic];
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    } finally {
      controller.close();
    }
    return registerComics(
      imported,
      false,
      cleanupManagedDirectoriesOnFailure: true,
    );
  }

  Future<bool> multipleCbz() async {
    var picker = DirectoryPicker();
    var dir = await picker.pickDirectory(directAccess: true);
    if (dir != null) {
      var files = (await dir.list().toList()).whereType<File>().toList();
      const supportedExtensions = ['cbz', 'zip', '7z', 'cb7'];
      files.removeWhere(
        (e) => !supportedExtensions.contains(e.extension.toLowerCase()),
      );
      Map<String?, List<LocalComic>> imported = {};
      var controller = showLoadingDialog(App.rootContext, allowCancel: false);
      var comics = <LocalComic>[];
      try {
        for (var file in files) {
          try {
            var comic = await CBZ.import(file);
            comics.add(comic);
          } catch (e, s) {
            Log.error("Import Comic", e.toString(), s);
          }
        }
        if (comics.isEmpty) {
          App.rootContext.showMessage(message: "No valid comics found".tl);
        }
        imported[selectedFolder] = comics;
      } finally {
        controller.close();
      }
      return registerComics(
        imported,
        false,
        cleanupManagedDirectoriesOnFailure: true,
      );
    }
    return false;
  }

  Future<bool> ehViewer() async {
    var dbFile = await selectFile(ext: ['db']);
    final picker = DirectoryPicker();
    final comicSrc = await picker.pickDirectory();
    Map<String?, List<LocalComic>> imported = {};
    if (dbFile == null || comicSrc == null) {
      return false;
    }

    bool cancelled = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () {
        cancelled = true;
      },
    );

    sql.Database? db;
    try {
      db = sql.sqlite3.open(dbFile.path);

      Future<List<LocalComic>> validateComics(List<sql.Row> comics) async {
        List<LocalComic> imported = [];
        for (var comic in comics) {
          if (cancelled) {
            return imported;
          }
          final dirName = comic['DIRNAME']?.toString();
          if (dirName == null || dirName.isEmpty) {
            continue;
          }
          var comicDir = Directory(FilePath.join(comicSrc.path, dirName));
          String titleJP = comic['TITLE_JPN']?.toString() ?? "";
          String title = titleJP == ""
              ? (comic['TITLE']?.toString() ?? dirName)
              : titleJP;
          int timeStamp = switch (comic['TIME']) {
            int value => value,
            String value => int.tryParse(value) ?? 0,
            _ => 0,
          };
          DateTime downloadTime = timeStamp != 0
              ? DateTime.fromMillisecondsSinceEpoch(timeStamp)
              : DateTime.now();
          final categoryTag = safeEhViewerCategoryTag(comic['CATEGORY']);
          var comicObj = await _checkSingleComic(
            comicDir,
            title: title,
            tags: categoryTag == null ? const [] : [categoryTag],
            createTime: downloadTime,
          );
          if (comicObj == null) {
            continue;
          }
          imported.add(comicObj);
        }
        return imported;
      }

      var tags = <String>[""];
      tags.addAll(
        db
            .select("""
            SELECT * FROM DOWNLOAD_LABELS LB
            ORDER BY  LB.TIME DESC;
          """)
            .map((r) => r['LABEL'])
            .whereType<String>()
            .toList(),
      );

      for (var tag in tags) {
        if (cancelled) {
          break;
        }
        var folderName = tag == '' ? '(EhViewer)Default'.tl : '(EhViewer)$tag';
        var comicList = db.select("""
              SELECT * 
              FROM DOWNLOAD_DIRNAME DN
              LEFT JOIN DOWNLOADS DL
              ON DL.GID = DN.GID
              WHERE DL.LABEL ${tag == '' ? 'IS NULL' : '= ?'} AND DL.STATE = 3
              ORDER BY DL.TIME DESC
            """, tag == '' ? const [] : [tag]).toList();

        var validComics = await validateComics(comicList);
        imported[folderName] = validComics;
        if (validComics.isNotEmpty &&
            !LocalFavoritesManager().existsFolder(folderName)) {
          LocalFavoritesManager().createFolder(folderName);
        }
      }
      //Android specific
      var cache = FilePath.join(App.cachePath, dbFile.name);
      await File(cache).deleteIgnoreError();
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    } finally {
      // Keep the local SQLite handle scoped to the import operation. Import can
      // be cancelled or fail on malformed external data.
      db?.close();
      controller.close();
    }
    if (cancelled) return false;
    return registerComics(imported, copyToLocal);
  }

  Future<bool> directory(bool single) async {
    final picker = DirectoryPicker();
    final path = await picker.pickDirectory();
    if (path == null) {
      return false;
    }
    Map<String?, List<LocalComic>> imported = {selectedFolder: []};
    try {
      if (single) {
        var result = await _checkSingleComic(path);
        if (result != null) {
          imported[selectedFolder]!.add(result);
        } else {
          App.rootContext.showMessage(message: "Invalid Comic".tl);
          return false;
        }
      } else {
        await for (var entry in path.list()) {
          if (entry is Directory) {
            var result = await _checkSingleComic(entry);
            if (result != null) {
              imported[selectedFolder]!.add(result);
            }
          }
        }
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    }
    return registerComics(imported, copyToLocal);
  }

  Future<bool> localDownloads() async {
    var localDir = LocalManager().directory;
    Map<String?, List<LocalComic>> imported = {null: []};
    bool cancelled = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () {
        cancelled = true;
      },
    );
    try {
      if (!await localDir.exists()) {
        App.rootContext.showMessage(message: "Local path not found".tl);
        return false;
      }
      await for (var entry in localDir.list()) {
        if (cancelled) {
          break;
        }
        if (entry is Directory) {
          var stat = await entry.stat();
          var result = await _checkSingleComic(
            entry,
            createTime: stat.modified,
            useRelativePath: true,
          );
          if (result != null) {
            imported[null]!.add(result);
          }
        }
      }
      if (!cancelled && imported[null]!.isEmpty) {
        App.rootContext.showMessage(message: "No valid comics found".tl);
      }
    } catch (e, s) {
      Log.error("Import Comic", e.toString(), s);
      App.rootContext.showMessage(message: e.toString());
    } finally {
      controller.close();
    }
    if (cancelled) return false;
    return registerComics(imported, false);
  }

  //Automatically search for cover image and chapters
  Future<LocalComic?> _checkSingleComic(
    Directory directory, {
    String? id,
    String? title,
    String? subtitle,
    List<String>? tags,
    DateTime? createTime,
    bool useRelativePath = false,
  }) async {
    if (!(await directory.exists())) return null;
    var name = title ?? directory.name;
    if (LocalManager().findByName(name) != null) {
      Log.info("Import Comic", "Comic already exists: $name");
      return null;
    }
    bool hasChapters = false;
    var chapters = <String>[];
    var coverPath = ''; // relative path to the cover image
    var fileList = <String>[];
    final chapterImages = <String, List<String>>{};
    await for (var entry in directory.list()) {
      if (entry is Directory) {
        final images = <String>[];
        await for (var file in entry.list()) {
          if (file is Directory) {
            Log.info(
              "Import Comic",
              "Invalid Chapter: ${entry.name}\nA directory is found in the chapter directory.",
            );
            return null;
          } else if (file is File &&
              isSupportedImportedComicImageExtension(file.extension)) {
            images.add(file.name);
          }
        }
        if (images.isNotEmpty) {
          hasChapters = true;
          images.sort();
          chapters.add(entry.name);
          chapterImages[entry.name] = images;
        }
      } else if (entry is File) {
        if (isSupportedImportedComicImageExtension(entry.extension)) {
          fileList.add(entry.name);
        }
      }
    }

    if (fileList.isEmpty && !hasChapters) {
      return null;
    }

    fileList.sort();
    if (fileList.isNotEmpty) {
      coverPath =
          fileList.firstWhereOrNull(
            (l) => l.toLowerCase().startsWith('cover'),
          ) ??
          fileList.first;
    }

    chapters.sort();
    if (hasChapters && fileList.isEmpty) {
      // use the first image in the first chapter as the cover
      var firstChapterName = chapters.first;
      final firstChapterImages = chapterImages[firstChapterName] ?? const [];
      final chapterCover =
          firstChapterImages.firstWhereOrNull(
            (l) => l.toLowerCase().startsWith('cover'),
          ) ??
          firstChapterImages.firstOrNull;
      if (chapterCover != null) {
        coverPath = FilePath.join(firstChapterName, chapterCover);
      }
    }
    if (coverPath == '') {
      Log.info("Import Comic", "Invalid Comic: $name\nNo cover image found.");
      return null;
    }
    var directoryPath = useRelativePath ? directory.name : directory.path;
    return LocalComic(
      id: id ?? '0',
      title: name,
      subtitle: subtitle ?? '',
      tags: tags ?? [],
      directory: directoryPath,
      chapters: hasChapters
          ? ComicChapters(Map.fromIterables(chapters, chapters))
          : null,
      cover: coverPath,
      comicType: ComicType.local,
      downloadedChapters: chapters,
      createdAt: createTime ?? DateTime.now(),
    );
  }

  @visibleForTesting
  Future<LocalComic?> debugCheckSingleComic(Directory directory) {
    return _checkSingleComic(directory);
  }

  static Future<Map<String, String>> _copyDirectories(
    Map<String, dynamic> data,
  ) async {
    return overrideIO(() async {
      final rawToBeCopied = data['toBeCopied'];
      final destination = data['destination'];
      if (rawToBeCopied is! Iterable || destination is! String) {
        return <String, String>{};
      }
      var toBeCopied = rawToBeCopied
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toList();
      Map<String, String> result = {};
      final copiedDestinations = <String>{};
      for (var dir in toBeCopied) {
        var source = Directory(dir);
        var dest = Directory(FilePath.join(destination, source.name));
        Directory? backup;
        if (dest.existsSync() &&
            copiedDestinations.contains(
              normalizeOutputFilePathForLock(dest.path),
            )) {
          dest = Directory(
            FilePath.join(
              destination,
              findValidDirectoryName(destination, source.name),
            ),
          );
        } else if (dest.existsSync()) {
          // The destination directory already exists, and it is not managed by the app.
          // Rename the old directory to avoid conflicts.
          Log.info(
            "Import Comic",
            "Directory already exists: ${source.name}\nRenaming the old directory.",
          );
          backup = dest.renameSync(buildImportBackupDirectoryPath(dest));
        }
        try {
          dest.createSync();
          await copyDirectory(source, dest);
          copiedDestinations.add(normalizeOutputFilePathForLock(dest.path));
          result[source.path] = dest.path;
        } catch (_) {
          await dest.deleteIgnoreError(recursive: true);
          if (backup != null && backup.existsSync() && !dest.existsSync()) {
            backup.renameSync(dest.path);
          }
          rethrow;
        }
      }
      return result;
    });
  }

  @visibleForTesting
  static Future<Map<String, String>> debugCopyDirectories(
    Map<String, dynamic> data,
  ) {
    return _copyDirectories(data);
  }

  Future<Map<String?, List<LocalComic>>> _copyComicsToLocalDir(
    Map<String?, List<LocalComic>> comics,
  ) async {
    var destPath = LocalManager().path;
    Map<String?, List<LocalComic>> result = {};
    for (var favoriteFolder in comics.keys) {
      result[favoriteFolder] = comics[favoriteFolder]!
          .where((c) => c.directory.startsWith(destPath))
          .toList();
      comics[favoriteFolder]!.removeWhere(
        (c) => c.directory.startsWith(destPath),
      );

      if (comics[favoriteFolder]!.isEmpty) {
        continue;
      }

      try {
        // copy the comics to the local directory
        var pathMap = await compute<Map<String, dynamic>, Map<String, String>>(
          _copyDirectories,
          {
            'toBeCopied': comics[favoriteFolder]!
                .map((e) => e.directory)
                .toList(),
            'destination': destPath,
          },
        );
        //Construct a new object since LocalComic.directory is a final String
        for (var c in comics[favoriteFolder]!) {
          result[favoriteFolder]!.add(
            LocalComic(
              id: c.id,
              title: c.title,
              subtitle: c.subtitle,
              tags: c.tags,
              directory: pathMap[c.directory]!,
              chapters: c.chapters,
              cover: c.cover,
              comicType: c.comicType,
              downloadedChapters: c.downloadedChapters,
              createdAt: c.createdAt,
            ),
          );
        }
      } catch (e, s) {
        App.rootContext.showMessage(message: "Failed to copy comics".tl);
        Log.error("Import Comic", e.toString(), s);
        return result;
      }
    }
    return result;
  }

  Future<bool> registerComics(
    Map<String?, List<LocalComic>> importedComics,
    bool copy, {
    bool cleanupManagedDirectoriesOnFailure = false,
  }) async {
    final registered = <_RegisteredImportedComic>[];
    final managedDirectories = <String>{};
    try {
      if (copy) {
        importedComics = await _copyComicsToLocalDir(importedComics);
        cleanupManagedDirectoriesOnFailure = true;
      }
      if (cleanupManagedDirectoriesOnFailure) {
        managedDirectories.addAll(
          importedComics.values
              .expand((comics) => comics)
              .map((comic) => comic.baseDir),
        );
      }
      int importedCount = 0;
      for (var folder in importedComics.keys) {
        for (var comic in importedComics[folder]!) {
          var id = LocalManager().findValidId(ComicType.local);
          await LocalManager().add(comic, id);
          final registration = _RegisteredImportedComic(
            id: id,
            type: comic.comicType,
            folder: folder,
          );
          registered.add(registration);
          if (folder != null) {
            final favoriteAdded = LocalFavoritesManager().addComic(
              folder,
              FavoriteItem(
                id: id,
                name: comic.title,
                coverPath: comic.cover,
                author: comic.subtitle,
                type: comic.comicType,
                tags: comic.tags,
                favoriteTime: comic.createdAt,
              ),
            );
            if (!favoriteAdded) {
              throw StateError(
                'Imported comic already exists in favorite folder: $folder',
              );
            }
            registration.favoriteAdded = true;
          }
          importedCount++;
        }
      }
      if (importedCount == 0) {
        return false;
      }
      _showRegistrationMessage("Imported @a comics", {'a': importedCount});
    } catch (e, s) {
      await _rollbackRegistrations(registered);
      if (cleanupManagedDirectoriesOnFailure) {
        await _deleteManagedImportDirectories(managedDirectories);
      }
      _showRegistrationMessage("Failed to register comics");
      Log.error("Import Comic", e.toString(), s);
      return false;
    }
    return true;
  }

  void _showRegistrationMessage(
    String message, [
    Map<String, Object> parameters = const {},
  ]) {
    final context = App.rootNavigatorKey.currentContext;
    if (context == null) {
      return;
    }
    context.showMessage(
      message: parameters.isEmpty ? message.tl : message.tlParams(parameters),
    );
  }

  Future<void> _rollbackRegistrations(
    List<_RegisteredImportedComic> registered,
  ) async {
    for (final registration in registered.reversed) {
      if (registration.favoriteAdded && registration.folder != null) {
        try {
          LocalFavoritesManager().deleteComicWithId(
            registration.folder!,
            registration.id,
            registration.type,
          );
        } catch (error, stackTrace) {
          Log.error(
            'Import Comic',
            'Failed to roll back favorite ${registration.id}: $error',
            stackTrace,
          );
        }
      }
      try {
        LocalManager().remove(registration.id, registration.type);
      } catch (error, stackTrace) {
        Log.error(
          'Import Comic',
          'Failed to roll back local comic ${registration.id}: $error',
          stackTrace,
        );
      }
    }
  }

  Future<void> _deleteManagedImportDirectories(
    Iterable<String> directories,
  ) async {
    final localRoot = p.normalize(p.absolute(LocalManager().path));
    for (final path in directories) {
      final candidate = p.normalize(p.absolute(path));
      if (candidate == localRoot || !p.isWithin(localRoot, candidate)) {
        Log.warning(
          'Import Comic',
          'Skip cleanup outside the managed local directory: $candidate',
        );
        continue;
      }
      await Directory(candidate).deleteIgnoreError(recursive: true);
    }
  }
}

class _RegisteredImportedComic {
  _RegisteredImportedComic({
    required this.id,
    required this.type,
    required this.folder,
  });

  final String id;
  final ComicType type;
  final String? folder;
  bool favoriteAdded = false;
}
