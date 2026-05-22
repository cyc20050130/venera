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

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
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
  Widget buildContent(BuildContext context, ReaderProps data) {
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
