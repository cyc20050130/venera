part of 'comic_page.dart';

@visibleForTesting
const double comicThumbnailMaxCrossAxisExtent = 200;

@visibleForTesting
const double comicThumbnailChildAspectRatio = 0.68;

@visibleForTesting
({String url, ImagePart? part}) parseComicThumbnailSpec(String raw) {
  final marker = raw.indexOf('@');
  if (marker <= 0 || marker == raw.length - 1) {
    return (url: raw, part: null);
  }

  final url = raw.substring(0, marker);
  final params = raw.substring(marker + 1).split('&');
  double? x1, y1, x2, y2;

  for (final param in params) {
    final separator = param.indexOf('=');
    if (separator <= 0 || separator == param.length - 1) {
      continue;
    }
    final key = param.substring(0, separator);
    final range = param.substring(separator + 1).split('-');
    if (range.length != 2) {
      continue;
    }
    final start = double.tryParse(range[0]);
    final end = double.tryParse(range[1]);
    if (start == null || end == null) {
      continue;
    }
    if (key.startsWith('x')) {
      x1 = start;
      x2 = end;
    } else if (key.startsWith('y')) {
      y1 = start;
      y2 = end;
    }
  }

  final part = x1 == null && y1 == null && x2 == null && y2 == null
      ? null
      : ImagePart(x1: x1, y1: y1, x2: x2, y2: y2);
  return (url: url, part: part);
}

class _ComicThumbnails extends StatefulWidget {
  const _ComicThumbnails({this.enabled = true});

  final bool enabled;

  @override
  State<_ComicThumbnails> createState() => _ComicThumbnailsState();
}

class _ComicThumbnailsState extends State<_ComicThumbnails> {
  late _ComicPageState state;

  late List<String> thumbnails;

  bool isInitialLoading = true;

  String? next;

  String? error;

  bool isLoading = false;
  bool hasRequestedInitialLoad = false;
  int _loadRequestId = 0;

  @override
  void dispose() {
    _loadRequestId++;
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    state = context.findAncestorStateOfType<_ComicPageState>()!;
    thumbnails = List.from(state.comic.thumbnails ?? []);
    super.didChangeDependencies();
    if (widget.enabled && !hasRequestedInitialLoad) {
      hasRequestedInitialLoad = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          state._logPerf('thumbnails initial load start');
          loadNext();
        }
      });
    }
  }

  void loadNext() async {
    final source = state.comicSource;
    final thumbnailLoader = source?.loadComicThumbnail;
    if (thumbnailLoader == null) return;
    if (!isInitialLoading && next == null) {
      return;
    }
    if (isLoading) return;
    final requestId = _loadRequestId;
    Future.microtask(() {
      if (!mounted || requestId != _loadRequestId) return;
      setState(() {
        isLoading = true;
      });
    });
    var res = await thumbnailLoader(state.comic.id, next);
    if (!mounted || requestId != _loadRequestId) return;
    if (res.success) {
      thumbnails.addAll(res.data);
      next = normalizeComicPaginationCursor(res.subData);
      isInitialLoading = false;
      state._logPerf('thumbnails load complete');
    } else {
      error = res.errorMessage;
      state._logPerf('thumbnails load failed');
    }
    setState(() {
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final thumbnailCacheWidth = resolveCoverDecodeDimension(
      comicThumbnailMaxCrossAxisExtent,
      devicePixelRatio,
    );
    final thumbnailCacheHeight = resolveCoverDecodeDimension(
      comicThumbnailMaxCrossAxisExtent / comicThumbnailChildAspectRatio,
      devicePixelRatio,
    );
    return MultiSliver(
      children: [
        SliverToBoxAdapter(child: ListTile(title: Text("Preview".tl))),
        SliverGrid(
          delegate: SliverChildBuilderDelegate(childCount: thumbnails.length, (
            context,
            index,
          ) {
            if (index == thumbnails.length - 1 && error == null) {
              loadNext();
            }
            final thumbnail = parseComicThumbnailSpec(thumbnails[index]);
            return Padding(
              padding: context.width < changePoint
                  ? const EdgeInsets.all(4)
                  : const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => state.read(null, index + 1),
                      borderRadius: const BorderRadius.all(Radius.circular(8)),
                      child: Container(
                        foregroundDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        width: double.infinity,
                        height: double.infinity,
                        clipBehavior: Clip.antiAlias,
                        child: AnimatedImage(
                          image: CachedImageProvider(
                            thumbnail.url,
                            sourceKey: state.widget.sourceKey,
                            cid: state.comic.id,
                          ),
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                          part: thumbnail.part,
                          cacheWidth: thumbnailCacheWidth,
                          cacheHeight: thumbnailCacheHeight,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text((index + 1).toString()),
                ],
              ),
            );
          }),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: comicThumbnailMaxCrossAxisExtent,
            childAspectRatio: comicThumbnailChildAspectRatio,
          ),
        ),
        if (error != null)
          SliverToBoxAdapter(
            child: Column(
              children: [
                Text(error!),
                Button.outlined(onPressed: loadNext, child: Text("Retry".tl)),
              ],
            ),
          )
        else if (isLoading)
          const SliverListLoadingIndicator(),
        const SliverToBoxAdapter(child: Divider()),
      ],
    );
  }
}
