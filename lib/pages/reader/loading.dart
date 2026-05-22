part of 'reader.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
    this.initialChapterGroup,
    this.seed,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  final int? initialChapterGroup;

  final ReaderProps? seed;

  @visibleForTesting
  static Widget Function(ReaderProps data)? debugReaderBuilder;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
  static const _kMinimumReaderMountDelay = Duration(milliseconds: 180);

  Animation<double>? _routeAnimation;
  bool _routeAnimationCompleted = false;
  bool _shellFirstFrameLogged = false;
  bool _shellSettled = false;
  bool _readerMountDelayScheduled = false;
  bool _readerMountScheduled = false;
  bool _readerMounted = false;
  bool _readerContentMountedLogged = false;
  late final Stopwatch _routePushStopwatch;

  @override
  ReaderProps? get initialData {
    final seed = widget.seed;
    if (seed == null) {
      return null;
    }
    _logPerf('reader seed hit', seed.type.sourceKey, seed.cid);
    return seed;
  }

  @override
  void initState() {
    _routePushStopwatch = Stopwatch()..start();
    _logPerf('reader route push', widget.sourceKey, widget.id);
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (animation != _routeAnimation) {
      _routeAnimation?.removeStatusListener(_handleRouteAnimationStatusChanged);
      _routeAnimation = animation;
      _routeAnimation?.addStatusListener(_handleRouteAnimationStatusChanged);
    }
    final isCompleted =
        animation == null || animation.status == AnimationStatus.completed;
    if (isCompleted && !_routeAnimationCompleted) {
      _routeAnimationCompleted = true;
      _logPerf('reader route animation completed', widget.sourceKey, widget.id);
    }
    _scheduleReaderMountIfReady();
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatusChanged);
    super.dispose();
  }

  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    if (!_readerMounted) {
      _scheduleShellFirstFrame();
      return _ReaderLoadingShell(title: data.name);
    }
    if (!_readerContentMountedLogged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _readerContentMountedLogged) {
          return;
        }
        _readerContentMountedLogged = true;
        _logPerf('reader content mounted', data.type.sourceKey, data.cid);
      });
    }
    final builder = ReaderWithLoading.debugReaderBuilder;
    if (builder != null) {
      return builder(data);
    }
    return Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: widget.initialEp ?? data.history.ep,
      initialPage: widget.initialPage ?? data.history.page,
      initialChapterGroup: resolveReaderInitialChapterGroup(
        requestedGroup: widget.initialChapterGroup,
        historyGroup: data.history.group,
      ),
      author: data.author,
      tags: data.tags,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    if (widget.seed != null) {
      return Res(widget.seed!);
    }
    var comicSource = ComicSource.find(widget.sourceKey);
    var history = HistoryManager().findBySourceKey(widget.id, widget.sourceKey);
    if (comicSource == null) {
      var localComic = LocalManager().find(
        widget.id,
        ComicType.fromKey(widget.sourceKey),
      );
      if (localComic == null) {
        return Res.error("comic not found");
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: localComic.title,
          chapters: localComic.chapters,
          history:
              history ?? History.fromModel(model: localComic, ep: 0, page: 0),
          author: localComic.subtitle,
          tags: localComic.tags,
        ),
      );
    } else {
      _logPerf('reader seed fallback detail load', widget.sourceKey, widget.id);
      var comic = await ComicDetailsRepository().load(
        widget.sourceKey,
        widget.id,
      );
      if (comic.error) {
        return Res.fromErrorRes(comic);
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: comic.data.title,
          chapters: comic.data.chapters,
          history:
              history ?? History.fromModel(model: comic.data, ep: 0, page: 0),
          author: comic.data.findAuthor() ?? "",
          tags: comic.data.plainTags,
        ),
      );
    }
  }

  void _logPerf(String label, String sourceKey, String comicId) {
    if (!kDebugMode) {
      return;
    }
    Log.info('ReaderWithLoading', '[perf] $label $sourceKey@$comicId');
  }

  void _handleRouteAnimationStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_routeAnimationCompleted) {
      _routeAnimationCompleted = true;
      _logPerf('reader route animation completed', widget.sourceKey, widget.id);
      _scheduleReaderMountIfReady();
    }
  }

  void _scheduleShellFirstFrame() {
    if (_shellFirstFrameLogged) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _shellFirstFrameLogged) {
        return;
      }
      _shellFirstFrameLogged = true;
      _logPerf('reader shell first frame', widget.sourceKey, widget.id);
      _scheduleReaderMountIfReady();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _shellSettled) {
          return;
        }
        _shellSettled = true;
        _scheduleReaderMountIfReady();
      });
    });
  }

  void _scheduleReaderMountIfReady() {
    if (_readerMounted ||
        !_shellFirstFrameLogged ||
        !_shellSettled ||
        !_routeAnimationCompleted ||
        data == null) {
      return;
    }
    final remainingDelay =
        _kMinimumReaderMountDelay - _routePushStopwatch.elapsed;
    if (remainingDelay > Duration.zero) {
      if (_readerMountDelayScheduled) {
        return;
      }
      _readerMountDelayScheduled = true;
      Future.delayed(remainingDelay, () {
        _readerMountDelayScheduled = false;
        if (mounted) {
          _scheduleReaderMountIfReady();
        }
      });
      return;
    }
    if (_readerMountScheduled) {
      return;
    }
    _readerMountScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _readerMounted) {
        return;
      }
      setState(() {
        _readerMounted = true;
      });
    });
  }
}

@visibleForTesting
int? resolveReaderInitialChapterGroup({
  required int? requestedGroup,
  required int? historyGroup,
}) {
  return requestedGroup ?? historyGroup;
}

class ReaderProps {
  final ComicType type;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
  });
}

class _ReaderLoadingShell extends StatelessWidget {
  const _ReaderLoadingShell({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  const BackButton(),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s18,
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(height: 16),
                    Text('正在打开阅读器', style: ts.s16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
