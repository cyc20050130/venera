import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';
import '../foundation/global_state.dart';
import 'package:venera/foundation/follow_updates.dart';

@visibleForTesting
List<int>? parseFollowUpdateTimeParts(String? value) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  final parts = value.split('-');
  final result = <int>[];
  for (final part in parts) {
    final parsed = int.tryParse(part.trim());
    if (parsed == null) {
      return null;
    }
    result.add(parsed);
  }
  return result;
}

@visibleForTesting
int compareFollowUpdateTime(String? a, String? b) {
  final aParts = parseFollowUpdateTimeParts(a);
  final bParts = parseFollowUpdateTimeParts(b);
  if (aParts == null && bParts == null) {
    return 0;
  }
  if (aParts == null) {
    return 1;
  }
  if (bParts == null) {
    return -1;
  }
  final length = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < length; i++) {
    final aValue = i < aParts.length ? aParts[i] : 0;
    final bValue = i < bParts.length ? bParts[i] : 0;
    if (aValue != bValue) {
      return bValue.compareTo(aValue);
    }
  }
  return 0;
}

@visibleForTesting
double? followUpdateProgressRatio(UpdateProgress progress) {
  if (progress.total <= 0) {
    return null;
  }
  final ratio = progress.current / progress.total;
  if (ratio.isNaN || ratio.isInfinite) {
    return null;
  }
  if (ratio < 0) {
    return 0;
  }
  if (ratio > 1) {
    return 1;
  }
  return ratio;
}

@visibleForTesting
bool shouldWaitForDataSyncBeforeFollowUpdate({
  required bool isDownloading,
  required bool isCanceled,
}) {
  return isDownloading && !isCanceled;
}

@visibleForTesting
bool shouldApplyFollowUpdateActionResult({
  required bool mounted,
  required int requestId,
  required int activeRequestId,
}) {
  return mounted && requestId == activeRequestId;
}

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;

  String? get folder =>
      resolveFollowUpdatesFolder(appdata.settings["followUpdatesFolder"]);

  void getCount() {
    if (folder == null) {
      _count = 0;
      return;
    }
    if (!LocalFavoritesManager().folderNames.contains(folder)) {
      _count = 0;
      appdata.settings["followUpdatesFolder"] = null;
      Future.microtask(() {
        appdata.saveDataInBackground();
      });
    } else {
      _count = LocalFavoritesManager().countUpdates(folder!);
    }
  }

  void updateCount() {
    setState(() {
      getCount();
    });
  }

  @override
  void initState() {
    super.initState();
    getCount();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => FollowUpdatesPage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(child: Text('Follow Updates'.tl, style: ts.s18)),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (_count > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  margin: const EdgeInsets.only(bottom: 16, left: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  child: Text(
                    '@c updates'.tlParams({'c': _count}),
                    style: ts.s16,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Object? get key => 'FollowUpdatesWidget';
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage> {
  String? get folder =>
      resolveFollowUpdatesFolder(appdata.settings["followUpdatesFolder"]);

  var updatedComics = <FavoriteItemWithUpdateInfo>[];
  var allComics = <FavoriteItemWithUpdateInfo>[];
  int _updateRequestId = 0;

  /// Sort comics by update time in descending order with nulls at the end.
  void sortComics() {
    allComics.sort((a, b) {
      return compareFollowUpdateTime(a.updateTime, b.updateTime);
    });
  }

  @override
  void initState() {
    super.initState();
    if (folder != null) {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder!);
      sortComics();
      updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('Follow Updates'.tl)),
          if (folder == null)
            buildNotConfigured(context)
          else
            buildConfigured(context),
          SliverPadding(padding: const EdgeInsets.only(top: 8)),
          buildUpdatedComics(),
          buildAllComics(),
        ],
      ),
    );
  }

  Widget buildNotConfigured(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text("Not Configured".tl),
            ),
            Text(
              "Choose a folder to follow updates.".tl,
              style: ts.s16,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: showSelector,
              child: Text("Choose Folder".tl),
            ).paddingHorizontal(16).toAlign(Alignment.centerRight),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildConfigured(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(leading: Icon(Icons.stars_outlined), title: Text(folder!)),
            Text(
              "Automatic update checking enabled.".tl,
              style: ts.s14,
            ).paddingHorizontal(16),
            Text(
              "The app will check for updates at most once a day.".tl,
              style: ts.s14,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: showSelector,
                  child: Text("Change Folder".tl),
                ),
                FilledButton.tonal(
                  onPressed: checkNow,
                  child: Text("Check Now".tl),
                ),
                const SizedBox(width: 16),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildUpdatedComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.update),
                const SizedBox(width: 8),
                Text("Updates".tl, style: ts.s18),
                const Spacer(),
                if (updatedComics.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.clear_all),
                    onPressed: () {
                      showConfirmDialog(
                        context: App.rootContext,
                        title: "Mark all as read".tl,
                        content: "Do you want to mark all as read?".tl,
                        onConfirm: () {
                          for (var comic in updatedComics) {
                            LocalFavoritesManager().markAsRead(
                              comic.id,
                              comic.type,
                            );
                          }
                          updateFollowUpdatesUI();
                          appdata.saveDataInBackground();
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        if (updatedComics.isNotEmpty)
          SliverToBoxAdapter(
            child: Text(
              "The comic will be marked as no updates as soon as you read it."
                  .tl,
            ).paddingHorizontal(16).paddingVertical(4),
          ),
        if (updatedComics.isNotEmpty)
          SliverGridComics(comics: updatedComics)
        else
          SliverToBoxAdapter(
            child: Row(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text("No updates found".tl, style: ts.s16)],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget buildAllComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.list),
                const SizedBox(width: 8),
                Text("All Comics".tl, style: ts.s18),
              ],
            ),
          ),
        ),
        SliverGridComics(comics: allComics),
      ],
    );
  }

  void showSelector() {
    var folders = LocalFavoritesManager().folderNames;
    if (folders.isEmpty) {
      context.showMessage(message: "No folders available".tl);
      return;
    }
    String? selectedFolder;
    showDialog(
      context: App.rootContext,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Choose Folder".tl,
              content: Column(
                children: [
                  ListTile(
                    title: Text("Folder".tl),
                    trailing: Select(
                      minWidth: 120,
                      current: selectedFolder,
                      values: folders,
                      onTap: (i) {
                        setState(() {
                          selectedFolder = folders[i];
                        });
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                if (resolveFollowUpdatesFolder(
                      appdata.settings["followUpdatesFolder"],
                    ) !=
                    null)
                  TextButton(
                    onPressed: () {
                      disable();
                      context.pop();
                    },
                    child: Text("Disable".tl),
                  ),
                FilledButton(
                  onPressed: selectedFolder == null
                      ? null
                      : () {
                          context.pop();
                          setFolder(selectedFolder!);
                        },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void disable() {
    _updateRequestId++;
    appdata.settings["followUpdatesFolder"] = null;
    appdata.saveDataInBackground();
    updateFollowUpdatesUI();
  }

  void setFolder(String folder) async {
    final requestId = ++_updateRequestId;
    FollowUpdatesService._cancelChecking?.call();
    LocalFavoritesManager().prepareTableForFollowUpdates(folder);

    var count = LocalFavoritesManager().count(folder);

    if (count > 0) {
      bool isCanceled = false;
      void onCancel() {
        isCanceled = true;
      }

      var loadingController = showLoadingDialog(
        App.rootContext,
        withProgress: true,
        cancelButtonText: "Cancel".tl,
        onCancel: onCancel,
        message: "Updating comics...".tl,
      );

      try {
        await for (var progress in updateFolder(folder, true)) {
          if (isCanceled) {
            return;
          }
          loadingController.setProgress(followUpdateProgressRatio(progress));
        }
      } catch (e, s) {
        if (!isCanceled && _shouldApplyUpdateResult(requestId)) {
          Log.error("FollowUpdates", "Failed to set update folder: $e", s);
        }
        return;
      } finally {
        loadingController.close();
      }
    }

    if (!_shouldApplyUpdateResult(requestId)) return;
    setState(() {
      appdata.settings["followUpdatesFolder"] = folder;
      updatedComics = [];
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
      sortComics();
    });
    appdata.saveDataInBackground();
  }

  void checkNow() async {
    final targetFolder = folder;
    if (targetFolder == null) {
      return;
    }
    final requestId = ++_updateRequestId;
    FollowUpdatesService._cancelChecking?.call();

    bool isCanceled = false;
    void onCancel() {
      isCanceled = true;
    }

    var loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: onCancel,
      message: "Updating comics...".tl,
    );

    int updated = 0;

    try {
      await for (var progress in updateFolder(targetFolder, true)) {
        if (isCanceled) {
          return;
        }
        loadingController.setProgress(followUpdateProgressRatio(progress));
        updated = progress.updated;
      }
    } catch (e, s) {
      if (!isCanceled && _shouldApplyUpdateResult(requestId)) {
        Log.error("FollowUpdates", "Failed to check updates: $e", s);
      }
      return;
    } finally {
      loadingController.close();
    }

    if (!_shouldApplyUpdateResult(requestId)) return;
    if (updated > 0) {
      GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
      updateComics();
    }
  }

  void updateComics() {
    if (!mounted) return;
    if (folder == null) {
      setState(() {
        allComics = [];
        updatedComics = [];
      });
      return;
    }
    setState(() {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder!);
      sortComics();
      updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
    });
  }

  bool _shouldApplyUpdateResult(int requestId) {
    return shouldApplyFollowUpdateActionResult(
      mounted: mounted,
      requestId: requestId,
      activeRequestId: _updateRequestId,
    );
  }

  @override
  Object? get key => 'FollowUpdatesPage';
}

/// Background service for checking updates
abstract class FollowUpdatesService {
  static bool _isChecking = false;

  static void Function()? _cancelChecking;

  static bool _isInitialized = false;

  static Timer? _timer;

  @visibleForTesting
  static bool get isCheckerInitialized => _isInitialized;

  @visibleForTesting
  static bool get hasScheduledChecker => _timer?.isActive ?? false;

  static Future<void> _check() async {
    if (_isChecking) {
      return;
    }
    var folder = resolveFollowUpdatesFolder(
      appdata.settings["followUpdatesFolder"],
    );
    if (folder == null) {
      return;
    }
    bool isCanceled = false;
    _cancelChecking = () {
      isCanceled = true;
    };

    _isChecking = true;

    int updated = 0;
    try {
      while (shouldWaitForDataSyncBeforeFollowUpdate(
        isDownloading: DataSync().isDownloading,
        isCanceled: isCanceled,
      )) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (isCanceled) {
        return;
      }
      await for (var progress in updateFolder(folder, false)) {
        if (isCanceled) {
          return;
        }
        updated = progress.updated;
      }
    } catch (e, s) {
      Log.error("FollowUpdates", "Background update check failed: $e\n$s");
    } finally {
      _cancelChecking = null;
      _isChecking = false;
      if (updated > 0) {
        updateFollowUpdatesUI();
      }
    }
  }

  static void _scheduleCheck() {
    unawaited(_check());
  }

  /// Initialize the checker.
  static void initChecker({
    bool scheduleInitialCheck = true,
    bool listenToDataSync = true,
  }) {
    if (_isInitialized) return;
    _isInitialized = true;
    if (scheduleInitialCheck) {
      _scheduleCheck();
    }
    if (listenToDataSync) {
      DataSync().addListener(updateFollowUpdatesUI);
    }
    // A short interval will not affect the performance since every comic has a check time.
    _timer = Timer.periodic(const Duration(minutes: 10), (timer) {
      _scheduleCheck();
    });
  }

  @visibleForTesting
  static void resetForTesting() {
    _cancelChecking?.call();
    _cancelChecking = null;
    _isChecking = false;
    _isInitialized = false;
    _timer?.cancel();
    _timer = null;
    if (DataSync.instance != null) {
      DataSync().removeListener(updateFollowUpdatesUI);
    }
  }
}

/// Update the UI of follow updates.
void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  GlobalState.findOrNull<_FollowUpdatesPageState>()?.updateComics();
}
