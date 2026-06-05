import 'dart:async';
import 'dart:convert';
import 'package:venera/foundation/comic_details_repository.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';

String? resolveFollowUpdatesFolder(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;

  ComicUpdateResult(this.updated, this.errorMessage);
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo c,
  String folder,
) async {
  int retries = 3;
  while (true) {
    try {
      var comicSource = c.type.comicSource;
      if (comicSource == null) {
        return ComicUpdateResult(false, "Comic source not found");
      }
      var newInfo = (await ComicDetailsRepository().load(
        comicSource.key,
        c.id,
        forceRefresh: true,
        refreshIfStale: false,
      )).data;

      var newTags = <String>[];
      for (var entry in newInfo.tags.entries) {
        const shouldIgnore = ['author', 'artist', 'time'];
        var namespace = entry.key;
        if (shouldIgnore.contains(namespace.toLowerCase())) {
          continue;
        }
        for (var tag in entry.value) {
          newTags.add("$namespace:$tag");
        }
      }

      var item = FavoriteItem(
        id: c.id,
        name: newInfo.title,
        coverPath: newInfo.cover,
        author:
            newInfo.subTitle ?? newInfo.tags['author']?.firstOrNull ?? c.author,
        type: c.type,
        tags: newTags,
      );

      LocalFavoritesManager().updateInfo(folder, item, false);

      var updated = false;
      var updateTime = newInfo.findUpdateTime();
      if (updateTime != null && updateTime != c.updateTime) {
        LocalFavoritesManager().updateUpdateTime(
          folder,
          c.id,
          c.type,
          updateTime,
        );
        updated = true;
      } else {
        LocalFavoritesManager().updateCheckTime(folder, c.id, c.type);
      }
      return ComicUpdateResult(updated, null);
    } catch (e, s) {
      Log.error("Check Updates", e, s);
      await Future.delayed(const Duration(seconds: 2));
      retries--;
      if (retries == 0) {
        return ComicUpdateResult(false, e.toString());
      }
    }
  }
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;

  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
  ]);
}

Future<void> updateFolderBase(
  String folder,
  StreamController<UpdateProgress> stream,
  bool ignoreCheckTime,
) async {
  await updateFolderBaseGuarded(folder, stream, ignoreCheckTime);
}

Future<void> updateFolderBaseGuarded(
  String folder,
  StreamController<UpdateProgress> stream,
  bool ignoreCheckTime, {
  bool Function()? isCanceled,
}) async {
  bool canceled() => isCanceled?.call() ?? false;

  void emit(UpdateProgress progress) {
    if (!canceled() && !stream.isClosed) {
      stream.add(progress);
    }
  }

  var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  int total = comics.length;
  int current = 0;
  int errors = 0;
  int updated = 0;

  emit(UpdateProgress(total, current, errors, updated));

  var comicsToUpdate = <FavoriteItemWithUpdateInfo>[];

  for (var comic in comics) {
    if (canceled()) {
      await stream.close();
      return;
    }
    if (!ignoreCheckTime) {
      var lastCheckTime = comic.lastCheckTime;
      if (lastCheckTime != null &&
          DateTime.now().difference(lastCheckTime).inDays < 1) {
        current++;
        emit(UpdateProgress(total, current, errors, updated));
        continue;
      }
    }
    comicsToUpdate.add(comic);
  }

  total = comicsToUpdate.length;
  current = 0;
  emit(UpdateProgress(total, current, errors, updated));

  var channel = Channel<FavoriteItemWithUpdateInfo>(10);

  // Producer
  final producer = () async {
    var c = 0;
    try {
      for (var comic in comicsToUpdate) {
        if (canceled()) {
          break;
        }
        await channel.push(comic);
        c++;
        // Throttle
        if (c % 5 == 0) {
          var delay = c % 100 + 1;
          if (delay > 10) {
            delay = 10;
          }
          await Future.delayed(Duration(seconds: delay));
        }
      }
    } finally {
      channel.close();
    }
  }();

  // Consumers
  var updateFutures = <Future>[];
  for (var i = 0; i < 5; i++) {
    var f = () async {
      while (true) {
        var comic = await channel.pop();
        if (comic == null) {
          break;
        }
        if (canceled()) {
          break;
        }
        var result = await updateComic(comic, folder);
        if (canceled()) {
          break;
        }
        current++;
        if (result.updated) {
          updated++;
        }
        if (result.errorMessage != null) {
          errors++;
        }
        emit(
          UpdateProgress(
            total,
            current,
            errors,
            updated,
            comic,
            result.errorMessage,
          ),
        );
      }
    }();
    updateFutures.add(f);
  }

  try {
    await Future.wait([producer, ...updateFutures]);

    if (!canceled() && updated > 0) {
      LocalFavoritesManager().notifyChanges();
    }
  } finally {
    if (!stream.isClosed) {
      await stream.close();
    }
  }
}

Stream<UpdateProgress> updateFolder(String folder, bool ignoreCheckTime) {
  var canceled = false;
  late final StreamController<UpdateProgress> stream;
  stream = StreamController<UpdateProgress>(
    onCancel: () {
      canceled = true;
    },
  );
  unawaited(
    updateFolderBaseGuarded(
      folder,
      stream,
      ignoreCheckTime,
      isCanceled: () => canceled,
    ).catchError((Object error, StackTrace stackTrace) async {
      Log.error("FollowUpdates", "Update stream failed: $error", stackTrace);
      if (!stream.isClosed) {
        stream.addError(error, stackTrace);
        await stream.close();
      }
    }),
  );
  return stream.stream;
}

Future<String> getUpdatedComicsAsJson(String folder) async {
  var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  var updatedComics = comics.where((c) => c.hasNewUpdate).toList();
  var jsonList = updatedComics
      .map(
        (c) => {
          'id': c.id,
          'name': c.name,
          'coverUrl': c.coverPath,
          'author': c.author,
          'type': c.type.sourceKey,
          'updateTime': c.updateTime,
          'tags': c.tags,
        },
      )
      .toList();
  return jsonEncode(jsonList);
}
