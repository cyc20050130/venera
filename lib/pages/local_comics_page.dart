import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/local_archive.dart';
import 'package:venera/foundation/local_archive_batch.dart';
import 'package:venera/foundation/local_archive_catalog.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';
import 'package:venera/utils/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LocalComicsPage extends StatefulWidget {
  const LocalComicsPage({super.key});

  @override
  State<LocalComicsPage> createState() => _LocalComicsPageState();
}

@visibleForTesting
LocalSortType normalizeLocalComicsSortType(Object? value) {
  if (value is String) {
    return LocalSortType.fromString(value);
  }
  return LocalSortType.name;
}

@visibleForTesting
enum LocalArchiveUiAction { compress, recompress, restore, none }

@visibleForTesting
LocalArchiveUiAction localArchiveUiActionForState(LocalStorageState? state) {
  return switch (state) {
    null || LocalStorageState.loose => LocalArchiveUiAction.compress,
    LocalStorageState.archived => LocalArchiveUiAction.restore,
    LocalStorageState.expanded => LocalArchiveUiAction.recompress,
    LocalStorageState.dirty => LocalArchiveUiAction.recompress,
    LocalStorageState.missing ||
    LocalStorageState.error => LocalArchiveUiAction.none,
  };
}

@visibleForTesting
String? localArchiveBadgeKey(
  LocalStorageState? state, {
  bool operationRunning = false,
}) {
  if (operationRunning) return 'Processing';
  return switch (state) {
    null => null,
    LocalStorageState.loose || LocalStorageState.dirty => 'Uncompressed',
    LocalStorageState.archived || LocalStorageState.expanded => 'Compressed',
    LocalStorageState.missing => 'Files missing',
    LocalStorageState.error => 'Compression error',
  };
}

@visibleForTesting
double localArchiveOperationProgress(LocalArchiveProgress progress) {
  return localArchiveOverallProgress(progress);
}

@visibleForTesting
String summarizeLocalArchiveFailures(
  Iterable<Object> failures, {
  int maxReasons = 3,
}) {
  final counts = <String, int>{};
  for (final failure in failures) {
    final reason = failure
        .toString()
        .replaceFirst('LocalArchiveException: ', '')
        .trim();
    final key = reason.isEmpty ? 'Unknown compression error' : reason;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final entries = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return entries
      .take(maxReasons.clamp(0, entries.length))
      .map((entry) => '${entry.value}× ${entry.key}')
      .join('; ');
}

@visibleForTesting
bool isLocalArchivePathManaged({
  required String libraryPath,
  required String comicPath,
}) {
  if (libraryPath.isEmpty || comicPath.isEmpty) return false;
  try {
    final library = p.canonicalize(p.absolute(libraryPath));
    final comic = p.canonicalize(p.absolute(comicPath));
    return p.isWithin(library, comic);
  } catch (_) {
    return false;
  }
}

enum _LocalArchiveUiOperation { compress, restore }

class _LocalComicsPageState extends State<LocalComicsPage> {
  late List<LocalComic> comics;

  late LocalSortType sortType;

  String keyword = "";

  bool searchMode = false;

  bool multiSelectMode = false;

  Map<LocalComic, bool> selectedComics = {};

  final Map<String, LocalArchiveSnapshot> _archiveSnapshots = {};

  final LocalArchiveCatalog _archiveCatalog = LocalArchiveCatalog();

  final Set<String> _visibleArchiveKeys = <String>{};

  final Map<String, LocalComic> _pendingVisibleArchiveRefresh =
      <String, LocalComic>{};

  final Set<String> _activeArchiveKeys = {};

  int _archiveRefreshGeneration = 0;

  Timer? _archiveRefreshDebounce;

  Timer? _visibleArchiveRefreshDebounce;

  bool _archiveOperationRunning = false;

  String _archiveKey(LocalComic comic) =>
      '${comic.comicType.value}\u0000${comic.sourceKey}\u0000${comic.id}\u0000${comic.directory}';

  bool _canArchive(LocalComic comic) =>
      !LocalManager().isDownloading(comic.id, comic.comicType) &&
      isLocalArchivePathManaged(
        libraryPath: LocalManager().path,
        comicPath: comic.baseDir,
      ) &&
      LocalArchiveService().canManage(comic);

  List<LocalComic> _queryComics() {
    if (keyword.isEmpty) {
      return LocalManager().getComics(sortType);
    }
    return LocalManager().search(keyword);
  }

  void update() {
    if (!mounted) return;
    setState(() {
      comics = _queryComics();
    });
    final currentKeys = comics.map(_archiveKey).toSet();
    _visibleArchiveKeys.retainAll(currentKeys);
    _pendingVisibleArchiveRefresh.removeWhere(
      (key, _) => !currentKeys.contains(key),
    );
    _archiveCatalog.retainComics(comics);
    if (!_archiveOperationRunning) {
      _scheduleArchiveRefresh();
    }
  }

  void _scheduleArchiveRefresh() {
    _archiveRefreshDebounce?.cancel();
    _archiveRefreshDebounce = Timer(const Duration(milliseconds: 150), () {
      unawaited(_refreshArchiveStates());
    });
  }

  void _onArchiveItemBuilt(Comic value) {
    if (value is! LocalComic) return;
    final key = _archiveKey(value);
    final firstVisibleBuild = _visibleArchiveKeys.add(key);
    if (!firstVisibleBuild && _archiveSnapshots.containsKey(key)) return;
    _pendingVisibleArchiveRefresh[key] = value;
    _visibleArchiveRefreshDebounce?.cancel();
    _visibleArchiveRefreshDebounce = Timer(
      const Duration(milliseconds: 16),
      () {
        if (!mounted || _pendingVisibleArchiveRefresh.isEmpty) return;
        final targets = _pendingVisibleArchiveRefresh.values.toList(
          growable: false,
        );
        _pendingVisibleArchiveRefresh.clear();
        unawaited(_refreshArchiveStates(targetComics: targets));
      },
    );
  }

  @override
  void initState() {
    super.initState();
    sortType = normalizeLocalComicsSortType(appdata.implicitData["local_sort"]);
    comics = LocalManager().getComics(sortType);
    LocalManager().addListener(update);
  }

  @override
  void dispose() {
    _archiveRefreshGeneration++;
    _archiveRefreshDebounce?.cancel();
    _visibleArchiveRefreshDebounce?.cancel();
    LocalManager().removeListener(update);
    super.dispose();
  }

  Future<void> _refreshArchiveStates({
    Iterable<LocalComic>? targetComics,
  }) async {
    final generation = ++_archiveRefreshGeneration;
    final targets =
        (targetComics ??
                comics.where(
                  (comic) => _visibleArchiveKeys.contains(_archiveKey(comic)),
                ))
            .where(_canArchive)
            .toList();
    final refreshed = <String, LocalArchiveSnapshot>{};
    for (final comic in targets) {
      final snapshot = await _archiveCatalog.inspectFast(comic);
      if (!mounted || generation != _archiveRefreshGeneration) return;
      refreshed[_archiveKey(comic)] = snapshot;
    }
    if (!mounted || generation != _archiveRefreshGeneration) return;
    final visibleKeys = comics.map(_archiveKey).toSet();
    setState(() {
      _archiveSnapshots.removeWhere((key, _) => !visibleKeys.contains(key));
      _archiveSnapshots.addAll(refreshed);
    });
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Sort".tl,
              content: RadioGroup<LocalSortType>(
                groupValue: sortType,
                onChanged: (v) {
                  setState(() {
                    sortType = v ?? sortType;
                  });
                },
                child: Column(
                  children: [
                    RadioListTile<LocalSortType>(
                      title: Text("Name".tl),
                      value: LocalSortType.name,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date".tl),
                      value: LocalSortType.timeAsc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date Desc".tl),
                      value: LocalSortType.timeDesc,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    appdata.implicitData["local_sort"] = sortType.value;
                    appdata.writeImplicitData();
                    Navigator.pop(context);
                    update();
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

  String? _archiveBadgeFor(LocalComic comic) {
    if (!_canArchive(comic)) return null;
    final key = _archiveKey(comic);
    final snapshot = _archiveSnapshots[key];
    return localArchiveBadgeKey(
      snapshot?.state ??
          (comic.hasArchiveMetadataOnDisk && !comic.hasDirtyArchiveMarkerOnDisk
              ? LocalStorageState.archived
              : LocalStorageState.loose),
      operationRunning: _activeArchiveKeys.contains(key),
    )?.tl;
  }

  List<MenuEntry> _archiveMenuEntries(LocalComic comic) {
    if (!_canArchive(comic) || _archiveOperationRunning) return const [];
    final snapshot = _archiveSnapshots[_archiveKey(comic)];
    final action = localArchiveUiActionForState(
      snapshot?.state ??
          (comic.hasArchiveMetadataOnDisk && !comic.hasDirtyArchiveMarkerOnDisk
              ? LocalStorageState.archived
              : LocalStorageState.loose),
    );
    return switch (action) {
      LocalArchiveUiAction.compress => [
        MenuEntry(
          icon: Icons.archive_outlined,
          text: 'Compress comic'.tl,
          onClick: () => unawaited(
            _runArchiveOperation([comic], _LocalArchiveUiOperation.compress),
          ),
        ),
      ],
      LocalArchiveUiAction.recompress => [
        MenuEntry(
          icon: Icons.sync,
          text: 'Compress comic'.tl,
          onClick: () => unawaited(
            _runArchiveOperation([comic], _LocalArchiveUiOperation.compress),
          ),
        ),
      ],
      LocalArchiveUiAction.restore => [
        MenuEntry(
          icon: Icons.unarchive_outlined,
          text: 'Open compressed comic'.tl,
          onClick: () => unawaited(
            _runArchiveOperation([comic], _LocalArchiveUiOperation.restore),
          ),
        ),
      ],
      LocalArchiveUiAction.none => const [],
    };
  }

  Future<void> _runArchiveOperation(
    List<LocalComic> requestedComics,
    _LocalArchiveUiOperation operation,
  ) async {
    if (_archiveOperationRunning || !mounted) return;
    final seen = <String>{};
    final targets = requestedComics
        .where(_canArchive)
        .where((comic) => seen.add(_archiveKey(comic)))
        .toList(growable: false);
    final skipped = requestedComics.length - targets.length;
    if (targets.isEmpty) {
      context.showMessage(
        message: 'Only Venera-managed comics can be compressed.'.tl,
      );
      return;
    }

    final token = LocalArchiveCancellationToken();
    final operationText = switch (operation) {
      _LocalArchiveUiOperation.compress => 'Compressing'.tl,
      _LocalArchiveUiOperation.restore => 'Opening'.tl,
    };
    setState(() {
      _archiveOperationRunning = true;
      _activeArchiveKeys.addAll(targets.map(_archiveKey));
    });

    final loadingController = showLoadingDialog(
      context,
      barrierDismissible: false,
      allowCancel: true,
      withProgress: true,
      message: '@action @current/@total'.tlParams({
        'action': operationText,
        'current': 0,
        'total': targets.length,
      }),
      onCancel: token.cancel,
    );
    final refreshed = <String, LocalArchiveSnapshot>{};
    final failures = <Object>[];
    var completed = 0;
    var cancelled = false;
    var lastDisplayedProgress = 0.0;
    var lastMessageElapsed = Duration.zero;
    LocalArchiveProgress? lastReportedProgress;
    LocalArchiveBatchProgress? lastBatchProgress;
    final operationStopwatch = Stopwatch()..start();
    String buildProgressMessage({required bool includeElapsed}) {
      final base = '@action @current/@total'.tlParams({
        'action': operationText,
        'current': lastBatchProgress?.completedItems ?? 0,
        'total': targets.length,
      });
      final progress = lastReportedProgress;
      if (progress == null) {
        return base;
      }
      final stage = localArchiveProgressStageKey(progress.operation).tl;
      final remaining = estimateLocalArchiveRemaining(
        elapsed: operationStopwatch.elapsed,
        progress: lastDisplayedProgress,
      );
      final eta = remaining == null
          ? ''
          : ' · ${'Estimated remaining @time'.tlParams({'time': formatLocalArchiveRemaining(remaining)})}';
      final elapsed = includeElapsed
          ? ' · ${'Elapsed @time'.tlParams({'time': formatLocalArchiveRemaining(operationStopwatch.elapsed)})}'
          : '';
      return '$base · $stage$eta$elapsed';
    }

    final heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      if (token.isCancelled || lastReportedProgress == null) {
        return;
      }
      final elapsed = operationStopwatch.elapsed;
      if (elapsed - lastMessageElapsed < const Duration(seconds: 2)) {
        return;
      }
      lastMessageElapsed = elapsed;
      loadingController.setMessage(buildProgressMessage(includeElapsed: true));
    });
    try {
      final comicsByKey = <String, LocalComic>{
        for (final comic in targets) _archiveKey(comic): comic,
      };
      final result = await runLocalArchiveBatch<LocalArchiveResult>(
        tasks: targets
            .map(
              (comic) => LocalArchiveBatchTask<LocalArchiveResult>(
                key: _archiveKey(comic),
                run: (cancellationToken, reportProgress) => switch (operation) {
                  _LocalArchiveUiOperation.compress =>
                    LocalArchiveService().compress(
                      comic,
                      cancellationToken: cancellationToken,
                      onProgress: reportProgress,
                    ),
                  _LocalArchiveUiOperation.restore =>
                    LocalArchiveService().restore(
                      comic,
                      cancellationToken: cancellationToken,
                      onProgress: reportProgress,
                    ),
                },
              ),
            )
            .toList(growable: false),
        maxConcurrency: App.isDesktop ? 2 : 1,
        cancellationToken: token,
        onProgress: (progress) {
          if (!mounted) {
            token.cancel();
            return;
          }
          lastBatchProgress = progress;
          lastReportedProgress = progress.latestProgress;
          final monotonic = progress.fraction.clamp(lastDisplayedProgress, 1.0);
          final elapsed = operationStopwatch.elapsed;
          if (monotonic - lastDisplayedProgress >= 0.005 ||
              elapsed - lastMessageElapsed >=
                  const Duration(milliseconds: 500) ||
              monotonic == 1.0) {
            lastDisplayedProgress = monotonic;
            lastMessageElapsed = elapsed;
            loadingController.setProgress(monotonic);
            loadingController.setMessage(
              buildProgressMessage(includeElapsed: false),
            );
          }
        },
      );
      refreshed.addAll(result.values);
      completed = result.values.length;
      cancelled = result.cancelled;
      for (final entry in result.values.entries) {
        final comic = comicsByKey[entry.key];
        if (comic != null) {
          unawaited(_archiveCatalog.remember(comic, entry.value));
        }
      }
      for (final entry in result.failures.entries) {
        final comic = comicsByKey[entry.key];
        final failure = entry.value;
        failures.add(failure.error);
        Log.error(
          'Local Archive',
          '${comic?.title ?? entry.key} '
              '(${comic?.sourceKey ?? 'unknown'}@${comic?.id ?? 'unknown'}): '
              '${failure.error}',
          failure.stackTrace,
        );
      }
    } on LocalArchiveCancelledException {
      cancelled = true;
    } finally {
      heartbeat.cancel();
      loadingController.close();
      if (mounted) {
        setState(() {
          _archiveSnapshots.addAll(refreshed);
          _activeArchiveKeys.clear();
          _archiveOperationRunning = false;
        });
      }
    }

    if (!mounted) return;
    unawaited(_refreshArchiveStates(targetComics: targets));
    if (cancelled || token.isCancelled) {
      context.showMessage(message: 'Operation canceled'.tl);
      return;
    }
    if (failures.isNotEmpty) {
      final detail = summarizeLocalArchiveFailures(failures);
      context.showMessage(
        message:
            '${'Operation failed for @count comics'.tlParams({'count': failures.length})}: $detail',
      );
      return;
    }
    final resultMessage = switch (operation) {
      _LocalArchiveUiOperation.compress => 'Compressed @count comics'.tlParams({
        'count': completed,
      }),
      _LocalArchiveUiOperation.restore => 'Opened @count comics'.tlParams({
        'count': completed,
      }),
    };
    final skippedMessage = skipped == 0
        ? ''
        : ' · ${'Skipped @count external comics'.tlParams({'count': skipped})}';
    context.showMessage(message: '$resultMessage$skippedMessage');
  }

  Widget buildMultiSelectMenu() {
    final selected = selectedComics.keys.toList(growable: false);
    return MenuButton(
      entries: [
        if (selected.any(_canArchive))
          MenuEntry(
            icon: Icons.archive_outlined,
            text: 'Compress comic'.tl,
            onClick: () => unawaited(
              _runArchiveOperation(selected, _LocalArchiveUiOperation.compress),
            ),
          ),
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            deleteComics(selectedComics.keys.toList()).then((value) {
              if (!mounted) return;
              if (value) {
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });
              }
            });
          },
        ),
        MenuEntry(
          icon: Icons.favorite_border,
          text: "Add to favorites".tl,
          onClick: () {
            addFavorite(selectedComics.keys.toList());
          },
        ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.folder_open,
            text: "Open Folder".tl,
            onClick: () {
              openComicFolder(selectedComics.keys.first);
            },
          ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.chrome_reader_mode_outlined,
            text: "View Detail".tl,
            onClick: () {
              context.to(
                () => ComicPage(
                  id: selectedComics.keys.first.id,
                  sourceKey: selectedComics.keys.first.sourceKey,
                ),
              );
            },
          ),
        if (selectedComics.isNotEmpty)
          ...exportActions(selectedComics.keys.toList()),
      ],
    );
  }

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      buildMultiSelectMenu(),
    ];

    List<Widget> normalActions = [
      Tooltip(
        message: "Search".tl,
        child: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              searchMode = true;
            });
          },
        ),
      ),
      Tooltip(
        message: "Sort".tl,
        child: IconButton(icon: const Icon(Icons.sort), onPressed: sort),
      ),
      Tooltip(
        message: "Downloading".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () {
            showPopUpWidget(context, const DownloadingPage());
          },
        ),
      ),
    ];

    var body = Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          if (!searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text("Local".tl),
              actions: multiSelectMode ? selectActions : normalActions,
            )
          else if (searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Cancel".tl,
                child: IconButton(
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.close),
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      setState(() {
                        searchMode = false;
                        keyword = "";
                        update();
                      });
                    }
                  },
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: "Search".tl,
                        border: InputBorder.none,
                      ),
                      onChanged: (v) {
                        keyword = v;
                        update();
                      },
                    ),
              actions: multiSelectMode ? selectActions : null,
            ),
          SliverGridComics(
            comics: comics,
            selections: selectedComics,
            onItemBuild: _onArchiveItemBuilt,
            badgeBuilder: (comic) => _archiveBadgeFor(comic as LocalComic),
            onLongPressed: (c, heroTag) {
              setState(() {
                multiSelectMode = true;
                selectedComics[c as LocalComic] = true;
              });
            },
            onTap: (c, heroTag) {
              if (multiSelectMode) {
                setState(() {
                  if (selectedComics.containsKey(c as LocalComic)) {
                    selectedComics.remove(c);
                  } else {
                    selectedComics[c] = true;
                  }
                  if (selectedComics.isEmpty) {
                    multiSelectMode = false;
                  }
                });
              } else {
                // prevent dirty data
                var comic = LocalManager().find(
                  c.id,
                  ComicType.fromKey(c.sourceKey),
                )!;
                comic.read();
                unawaited(_refreshArchiveStates(targetComics: [comic]));
              }
            },
            menuBuilder: (c) {
              return [
                ..._archiveMenuEntries(c as LocalComic),
                MenuEntry(
                  icon: Icons.folder_open,
                  text: "Open Folder".tl,
                  onClick: () {
                    openComicFolder(c);
                  },
                ),
                MenuEntry(
                  icon: Icons.delete,
                  text: "Delete".tl,
                  onClick: () {
                    deleteComics([c]).then((value) {
                      if (!mounted) return;
                      if (value && multiSelectMode) {
                        setState(() {
                          multiSelectMode = false;
                          selectedComics.clear();
                        });
                      }
                    });
                  },
                ),
                ...exportActions([c]),
              ];
            },
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            update();
          });
        }
      },
      child: body,
    );
  }

  Future<bool> deleteComics(List<LocalComic> comics) async {
    bool isDeleted = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Delete".tl,
          content: const Text("将删除本地漫画条目和磁盘文件，保留本地收藏与历史记录。"),
          actions: [
            if (comics.length == 1 && comics.first.hasChapters)
              TextButton(
                child: Text("Delete Chapters".tl),
                onPressed: () {
                  context.pop();
                  showDeleteChaptersPopWindow(context, comics.first);
                },
              ),
            FilledButton(
              onPressed: () {
                context.pop();
                LocalManager().batchDeleteComicsKeepFavoritesAndHistory(comics);
                isDeleted = true;
              },
              child: Text("Confirm".tl),
            ),
          ],
        );
      },
    );
    return isDeleted;
  }

  List<MenuEntry> exportActions(List<LocalComic> comics) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () {
          exportComics(comics, CBZ.export, ".cbz");
        },
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () async {
          exportComics(comics, createPdfFromComicIsolate, ".pdf");
        },
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () async {
          exportComics(comics, createEpubWithLocalComic, ".epub");
        },
      ),
    ];
  }

  /// Export given comics to a file
  void exportComics(
    List<LocalComic> comics,
    ExportComicFunc export,
    String ext,
  ) async {
    final operationId = const Uuid().v4();
    var current = 0;
    var cacheDir = buildComicsExportDirectory(App.cachePath, operationId);
    var outFile = buildComicsExportArchivePath(App.cachePath, operationId);
    bool canceled = false;
    bool archiveReadyForSave = false;
    final exportDirectory = Directory(cacheDir);
    if (await exportDirectory.exists()) {
      await exportDirectory.delete(recursive: true);
    }
    await exportDirectory.create(recursive: true);
    if (!mounted) {
      await exportDirectory.deleteIgnoreError(recursive: true);
      return;
    }
    var loadingController = showLoadingDialog(
      context,
      allowCancel: true,
      message: "${"Exporting".tl} $current/${comics.length}",
      withProgress: comics.length > 1,
      onCancel: () {
        canceled = true;
      },
    );
    try {
      var fileName = "";
      // For each comic, export it to a file
      for (var comic in comics) {
        if (canceled) return;
        if (comic.hasArchiveMetadataOnDisk &&
            !comic.hasDirtyArchiveMarkerOnDisk) {
          // PDF export reads the loose tree directly, while CBZ/EPUB use
          // LocalManager.getImages. Restore here so every export format has
          // identical archived-comic behavior and the retained ZIP stays
          // available for later cleanup.
          await LocalArchiveService().restore(comic);
        }
        fileName = FilePath.join(
          cacheDir,
          sanitizeFileName(comic.title, maxLength: 100) + ext,
        );
        await export(comic, fileName);
        current++;
        if (comics.length > 1) {
          if (shouldApplyLocalComicsExportResult(
            mounted: mounted,
            canceled: canceled,
          )) {
            loadingController.setMessage(
              "${"Exporting".tl} $current/${comics.length}",
            );
            loadingController.setProgress(current / comics.length);
          }
        }
        if (canceled) {
          return;
        }
      }
      // For single comic, just save the file
      if (comics.length == 1) {
        await saveFile(file: File(fileName), filename: File(fileName).name);
        await exportDirectory.delete(recursive: true);
        return;
      }
      // For multiple comics, compress the folder
      loadingController.setProgress(null);
      loadingController.setMessage("Compressing".tl);
      await ZipFile.compressFolderAsync(cacheDir, outFile);
      if (canceled) {
        return;
      }
      archiveReadyForSave = true;
    } catch (e, s) {
      Log.error("Export Comics", e, s);
      if (mounted && !canceled) {
        context.showMessage(message: e.toString());
      }
      return;
    } finally {
      loadingController.close();
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
      if (!archiveReadyForSave) {
        await File(outFile).deleteIgnoreError();
      }
      if (mounted) {
        unawaited(_refreshArchiveStates(targetComics: comics));
      }
    }
    try {
      await saveFile(file: File(outFile), filename: "comics_export.zip");
    } catch (e, s) {
      Log.error("Export Comics", "Failed to save exported comics: $e", s);
      if (mounted && !canceled) {
        context.showMessage(message: e.toString());
      }
    } finally {
      await File(outFile).deleteIgnoreError();
    }
  }
}

typedef ExportComicFunc =
    Future<File> Function(LocalComic comic, String outFilePath);

@visibleForTesting
bool shouldApplyLocalComicsExportResult({
  required bool mounted,
  required bool canceled,
}) {
  return mounted && !canceled;
}

@visibleForTesting
String buildComicsExportDirectory(String cachePath, String operationId) =>
    FilePath.join(cachePath, 'comics_export-$operationId');

@visibleForTesting
String buildComicsExportArchivePath(String cachePath, String operationId) =>
    FilePath.join(cachePath, 'comics_export-$operationId.zip');

/// Opens the folder containing the comic in the system file explorer
Future<void> openComicFolder(LocalComic comic) async {
  try {
    final folderPath = comic.baseDir;

    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      // For mobile platforms, use the URL launcher with file:// protocol
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open comic folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: "Failed to open folder: $e");
    }
  }
}

void showDeleteChaptersPopWindow(BuildContext context, LocalComic comic) {
  var chapters = <String>[];

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: comic.downloadedChapters.length,
                  itemBuilder: (context, index) {
                    var id = comic.downloadedChapters[index];
                    var chapter = comic.chapters![id] ?? "Unknown Chapter";
                    return CheckboxListTile(
                      title: Text(chapter),
                      value: chapters.contains(id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            chapters.add(id);
                          } else {
                            chapters.remove(id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: () {
                        final messageContext = App.rootContext;
                        unawaited(
                          Future.delayed(
                            const Duration(milliseconds: 200),
                            () async {
                              try {
                                await LocalManager().deleteComicChapters(
                                  comic,
                                  chapters,
                                );
                              } catch (error, stackTrace) {
                                Log.error(
                                  'LocalArchive',
                                  'Failed to delete comic chapters: $error',
                                  stackTrace,
                                );
                                if (messageContext.mounted) {
                                  messageContext.showMessage(
                                    message: error.toString(),
                                  );
                                }
                              }
                            },
                          ),
                        );
                        App.rootContext.pop();
                      },
                      child: Text("Submit".tl),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
