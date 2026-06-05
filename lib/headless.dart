import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/init.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';

void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

@visibleForTesting
Object? decodeHeadlessJsonPayload(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

@visibleForTesting
Map<String, dynamic> buildHeadlessUpdatedComicsOutput({
  required String status,
  required String json,
}) {
  final decoded = decodeHeadlessJsonPayload(json);
  if (decoded == null) {
    return {
      'status': 'error',
      'message': 'Updated comics list is malformed.',
      'data': <Object>[],
    };
  }
  return {
    'status': status,
    'message': 'Updated comics list.',
    'data': decoded,
  };
}

Future<void> runHeadlessMode(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if (Platform.isLinux || Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      Directory.current = home;
    }
  }
  // The first arg is '--headless', so we look at the next ones.
  var headlessIndex = args.indexOf('--headless');
  var commandIndex = headlessIndex + 1;
  if (headlessIndex < 0 || commandIndex >= args.length) {
    cliPrint({
      'status': 'error',
      'message': 'No command provided for headless mode.',
    });
    exit(1);
  }

  // Need to initialize the app for some features to work
  await init();

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length)
      ? args[commandIndex + 1]
      : null;

  switch (command) {
    case 'webdav':
      if (subCommand == 'up') {
        cliPrint({'status': 'running', 'message': 'Uploading WebDAV data...'});
        await DataSync().uploadData();
        cliPrint({'status': 'success', 'message': 'Upload complete.'});
      } else if (subCommand == 'down') {
        cliPrint({
          'status': 'running',
          'message': 'Downloading WebDAV data...',
        });
        await DataSync().downloadData();
        cliPrint({'status': 'success', 'message': 'Download complete.'});
      } else {
        cliPrint({
          'status': 'error',
          'message': 'Invalid webdav command. Use "up" or "down".',
        });
        exit(1);
      }
      break;
    case 'updatescript':
      if (subCommand == 'all') {
        cliPrint({
          'status': 'running',
          'message': 'Checking for comic source script updates...',
        });
        await ComicSourcePage.checkComicSourceUpdate();
        var updates = ComicSourceManager().availableUpdates;
        if (updates.isEmpty) {
          cliPrint({'status': 'success', 'message': 'No updates found.'});
        } else {
          var total = updates.length;
          var current = 0;
          var errors = 0;
          var updated = 0;
          cliPrint({
            'status': 'running',
            'message': 'Updating all comic source scripts...',
            'data': {'total': total, 'current': 0, 'updated': 0, 'errors': 0},
          });
          for (var key in updates.keys) {
            var source = ComicSource.find(key);
            if (source != null) {
              current++;
              var data = {
                'current': current,
                'total': total,
                'source': {
                  'key': source.key,
                  'name': source.name,
                  'version': source.version,
                  'url': source.url,
                },
              };
              try {
                await ComicSourcePage.update(source, false);
                updated++;
                cliPrint({
                  'status': 'running',
                  'message': 'Progress',
                  'data': data,
                });
              } catch (e) {
                errors++;
                cliPrint({
                  'status': 'running',
                  'message': 'ProgressError',
                  'data': {...data, 'error': e.toString()},
                });
              }
            }
          }
          cliPrint({
            'status': 'success',
            'message': 'All scripts updated.',
            'data': {'total': total, 'updated': updated, 'errors': errors},
          });
        }
      } else {
        cliPrint({
          'status': 'error',
          'message': 'Invalid updatescript command. Use "all".',
        });
        exit(1);
      }
      break;
    case 'updatesubscribe':
      cliPrint({
        'status': 'running',
        'message': 'Updating subscribed comics...',
      });
      var folder = resolveFollowUpdatesFolder(
        appdata.settings["followUpdatesFolder"],
      );
      if (folder == null) {
        cliPrint({
          'status': 'error',
          'message': 'Follow updates folder is not configured.',
        });
        exit(1);
      }

      var updateIndex = args.indexOf('--update-comic-by-id-type');
      if (updateIndex != -1) {
        if (updateIndex + 2 >= args.length) {
          cliPrint({
            'status': 'error',
            'message':
                'Missing arguments for --update-comic-by-id-type: expected id and type.',
          });
          exit(1);
        }
        var id = args[updateIndex + 1];
        var type = args[updateIndex + 2];
        var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
        FavoriteItemWithUpdateInfo? comic;
        for (var candidate in comics) {
          if (candidate.id == id && candidate.type.sourceKey == type) {
            comic = candidate;
            break;
          }
        }
        if (comic == null) {
          cliPrint({
            'status': 'error',
            'message': 'Comic not found for id "$id" and type "$type".',
          });
          exit(1);
        }

        var result = await updateComic(comic, folder);

        Map<String, dynamic> data = {
          'current': 1,
          'total': 1,
          'comic': {
            'id': comic.id,
            'name': comic.name,
            'coverUrl': comic.coverPath,
            'author': comic.author,
            'type': comic.type.sourceKey,
            'updateTime': comic.updateTime,
            'tags': comic.tags,
          },
        };

        var message = 'Progress';
        if (result.errorMessage != null) {
          message = 'ProgressError';
          data['error'] = result.errorMessage;
        }

        cliPrint({'status': 'running', 'message': message, 'data': data});

        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': 1,
            'updated': result.updated ? 1 : 0,
            'errors': result.errorMessage != null ? 1 : 0,
          },
        });

        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folder);
        cliPrint(
          buildHeadlessUpdatedComicsOutput(
            status: result.errorMessage != null ? 'error' : 'success',
            json: json,
          ),
        );
      } else {
        int total = 0;
        int updated = 0;
        int errors = 0;
        await for (var progress in updateFolder(folder, true)) {
          total = progress.total;
          updated = progress.updated;
          errors = progress.errors;
          Map<String, dynamic> data = {
            'current': progress.current,
            'total': progress.total,
          };
          if (progress.comic != null) {
            data['comic'] = {
              'id': progress.comic!.id,
              'name': progress.comic!.name,
              'coverUrl': progress.comic!.coverPath,
              'author': progress.comic!.author,
              'type': progress.comic!.type.sourceKey,
              'updateTime': progress.comic!.updateTime,
              'tags': progress.comic!.tags,
            };
          }
          var message = 'Progress';
          if (progress.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = progress.errorMessage;
          }
          cliPrint({'status': 'running', 'message': message, 'data': data});
        }
        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {'total': total, 'updated': updated, 'errors': errors},
        });
        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folder);
        cliPrint(
          buildHeadlessUpdatedComicsOutput(
            status: errors > 0 ? 'error' : 'success',
            json: json,
          ),
        );
      }
      break;
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  // Exit after command execution
  exit(0);
}
