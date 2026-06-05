part of 'comic_page.dart';

bool _shouldBlockComment(Comment comment) {
  var blockedWords = appdata.settings.stringList("blockedCommentWords");
  if (blockedWords.isEmpty) return false;

  var content = comment.content.toLowerCase();
  for (var word in blockedWords) {
    if (content.contains(word.toString().toLowerCase())) {
      return true;
    }
  }
  return false;
}

@visibleForTesting
bool shouldStartCommentLoad({required bool loading, required bool inFlight}) =>
    loading && !inFlight;

@visibleForTesting
bool shouldApplyCommentActionResult({
  required bool mounted,
  required int requestId,
  required int activeRequestId,
}) {
  return mounted && requestId == activeRequestId;
}

@visibleForTesting
int resolveCommentVoteStatus({required bool isUp, required bool isCancel}) {
  if (isCancel) {
    return 0;
  }
  return isUp ? 1 : -1;
}

class CommentsPage extends StatefulWidget {
  const CommentsPage({
    super.key,
    required this.data,
    required this.source,
    this.replyComment,
  });

  final ComicDetails data;

  final ComicSource source;

  final Comment? replyComment;

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  bool _loading = true;
  List<Comment>? _comments;
  String? _error;
  int _page = 1;
  int? maxPage;
  var controller = TextEditingController();
  bool sending = false;
  bool _firstLoadInFlight = false;
  bool _loadMoreInFlight = false;
  int _loadRequestId = 0;
  int _sendCommentRequestId = 0;

  @override
  void dispose() {
    _loadRequestId++;
    _sendCommentRequestId++;
    _firstLoadInFlight = false;
    _loadMoreInFlight = false;
    controller.dispose();
    super.dispose();
  }

  void firstLoad() async {
    if (!shouldStartCommentLoad(
      loading: _loading,
      inFlight: _firstLoadInFlight,
    )) {
      return;
    }
    _firstLoadInFlight = true;
    final requestId = ++_loadRequestId;
    late final Res<List<Comment>> res;
    try {
      res = await widget.source.commentsLoader!(
        widget.data.comicId,
        widget.data.subId,
        1,
        widget.replyComment?.id,
      );
    } catch (e) {
      res = Res.error(e.toString());
    }
    if (!mounted || requestId != _loadRequestId) return;
    _firstLoadInFlight = false;
    if (res.error) {
      setState(() {
        _error = res.errorMessage;
        _loading = false;
      });
      return;
    }
    var filteredComments = res.data
        .where((c) => !_shouldBlockComment(c))
        .toList();
    setState(() {
      _comments = filteredComments;
      _loading = false;
      maxPage = normalizeLoadingMaxPage(res.subData);
    });
  }

  void loadMore() async {
    if (_loadMoreInFlight) return;
    _loadMoreInFlight = true;
    final requestId = _loadRequestId;
    late final Res<List<Comment>> res;
    try {
      res = await widget.source.commentsLoader!(
        widget.data.comicId,
        widget.data.subId,
        _page + 1,
        widget.replyComment?.id,
      );
    } catch (e) {
      res = Res.error(e.toString());
    }
    if (!mounted || requestId != _loadRequestId) return;
    if (res.error) {
      setState(() {
        _loadMoreInFlight = false;
      });
      context.showMessage(message: res.errorMessage ?? "Unknown Error");
    } else {
      var filteredComments = res.data
          .where((c) => !_shouldBlockComment(c))
          .toList();
      setState(() {
        _loadMoreInFlight = false;
        _comments!.addAll(filteredComments);
        _page++;
        if (maxPage == null && res.data.isEmpty) {
          maxPage = _page;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: Appbar(title: Text("Comments".tl), style: AppbarStyle.shadow),
      body: buildBody(context),
    );
  }

  Widget buildBody(BuildContext context) {
    if (_loading) {
      firstLoad();
      return const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      return NetworkError(
        message: _error!,
        retry: () {
          setState(() {
            _loading = true;
            _error = null;
            _firstLoadInFlight = false;
            _loadMoreInFlight = false;
            _loadRequestId++;
          });
        },
        withAppbar: false,
      );
    } else {
      var showAvatar =
          _comments!.any((e) {
            return e.avatar != null;
          }) ||
          (widget.replyComment?.avatar != null);
      return Column(
        children: [
          Expanded(
            child: SmoothScrollProvider(
              builder: (context, controller, physics) {
                return ListView.builder(
                  controller: controller,
                  physics: physics,
                  primary: false,
                  padding: EdgeInsets.zero,
                  itemCount: _comments!.length + 2,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      if (widget.replyComment != null) {
                        return Column(
                          children: [
                            _CommentTile(
                              comment: widget.replyComment!,
                              source: widget.source,
                              comic: widget.data,
                              showAvatar: showAvatar,
                              showActions: false,
                            ),
                            const SizedBox(height: 8),
                            Container(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: context.colorScheme.outlineVariant,
                                    width: 0.6,
                                  ),
                                ),
                              ),
                              child: Text("Replies".tl, style: ts.s18),
                            ),
                          ],
                        );
                      } else {
                        return const SizedBox();
                      }
                    }
                    index--;

                    if (index == _comments!.length) {
                      if (_page < (maxPage ?? _page + 1)) {
                        loadMore();
                        return const ListLoadingIndicator();
                      } else {
                        return const SizedBox();
                      }
                    }

                    return _CommentTile(
                      comment: _comments![index],
                      source: widget.source,
                      comic: widget.data,
                      showAvatar: showAvatar,
                    );
                  },
                );
              },
            ),
          ),
          buildBottom(context),
        ],
      );
    }
  }

  Widget buildBottom(BuildContext context) {
    if (widget.source.sendCommentFunc == null) {
      return const SizedBox(height: 0);
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Material(
        color: context.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: "Comment".tl,
                ),
                minLines: 1,
                maxLines: 5,
              ),
            ),
            if (sending)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                onPressed: () async {
                  if (controller.text.isEmpty) {
                    return;
                  }
                  final requestId = ++_sendCommentRequestId;
                  final text = controller.text;
                  setState(() {
                    sending = true;
                  });

                  try {
                    var b = await widget.source.sendCommentFunc!(
                      widget.data.comicId,
                      widget.data.subId,
                      text,
                      widget.replyComment?.id,
                    );
                    if (!_shouldApplySendCommentResult(requestId)) {
                      return;
                    }
                    if (!b.error) {
                      controller.text = "";
                      setState(() {
                        sending = false;
                        _loading = true;
                        _error = null;
                        _comments?.clear();
                        _page = 1;
                        maxPage = null;
                        _firstLoadInFlight = false;
                        _loadMoreInFlight = false;
                        _loadRequestId++;
                      });
                    } else {
                      context.showMessage(message: b.errorMessage ?? "Error");
                      setState(() {
                        sending = false;
                      });
                    }
                  } catch (e, s) {
                    if (!_shouldApplySendCommentResult(requestId)) {
                      return;
                    }
                    Log.error(
                      "CommentsPage",
                      "Failed to send comment for ${widget.data.comicId}: $e",
                      s,
                    );
                    context.showMessage(message: e.toString());
                    setState(() {
                      sending = false;
                    });
                  }
                },
                icon: Icon(
                  Icons.send,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
          ],
        ).paddingLeft(16).paddingRight(4),
      ),
    );
  }

  bool _shouldApplySendCommentResult(int requestId) {
    return shouldApplyCommentActionResult(
      mounted: mounted,
      requestId: requestId,
      activeRequestId: _sendCommentRequestId,
    );
  }
}

class _CommentTile extends StatefulWidget {
  const _CommentTile({
    required this.comment,
    required this.source,
    required this.comic,
    required this.showAvatar,
    this.showActions = true,
  });

  final Comment comment;

  final ComicSource source;

  final ComicDetails comic;

  final bool showAvatar;

  final bool showActions;

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  @override
  void initState() {
    likes = widget.comment.score ?? 0;
    isLiked = widget.comment.isLiked ?? false;
    voteStatus = widget.comment.voteStatus;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final avatarCacheSize = resolveCoverDecodeDimension(36, devicePixelRatio);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showAvatar)
            Container(
              width: 36,
              height: 36,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: Theme.of(context).colorScheme.secondaryContainer,
              ),
              child: widget.comment.avatar == null
                  ? null
                  : AnimatedImage(
                      image: CachedImageProvider(
                        widget.comment.avatar!,
                        sourceKey: widget.source.key,
                      ),
                      cacheWidth: avatarCacheSize,
                      cacheHeight: avatarCacheSize,
                    ),
            ).paddingRight(8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.comment.userName, style: ts.bold),
                if (widget.comment.time != null)
                  Text(widget.comment.time!, style: ts.s12),
                const SizedBox(height: 4),
                _CommentContent(text: widget.comment.content),
                buildActions(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildActions() {
    if (!widget.showActions) {
      return const SizedBox();
    }
    if (widget.comment.score == null && widget.comment.replyCount == null) {
      return const SizedBox();
    }
    return SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (widget.comment.score != null &&
              widget.source.voteCommentFunc != null)
            buildVote(),
          if (widget.comment.score != null &&
              widget.source.likeCommentFunc != null)
            buildLike(),
          if (widget.comment.replyCount != null) buildReply(),
        ],
      ),
    ).paddingTop(8);
  }

  Widget buildReply() {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          showSideBar(
            context,
            CommentsPage(
              data: widget.comic,
              source: widget.source,
              replyComment: widget.comment,
            ),
            showBarrier: false,
          );
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_comment_outlined, size: 16),
            const SizedBox(width: 8),
            Text(widget.comment.replyCount.toString()),
          ],
        ).padding(const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
      ),
    );
  }

  bool isLiking = false;

  bool isLiked = false;

  int _likeRequestId = 0;

  int _voteRequestId = 0;

  var likes = 0;

  @override
  void dispose() {
    _likeRequestId++;
    _voteRequestId++;
    super.dispose();
  }

  Widget buildLike() {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          if (isLiking) return;
          final requestId = ++_likeRequestId;
          final wasLiked = isLiked;
          setState(() {
            isLiking = true;
          });

          try {
            var res = await widget.source.likeCommentFunc!(
              widget.comic.comicId,
              widget.comic.subId,
              widget.comment.id!,
              !wasLiked,
            );
            if (!_shouldApplyLikeResult(requestId)) {
              return;
            }
            if (res.success) {
              isLiked = !wasLiked;
              likes += isLiked ? 1 : -1;
            } else {
              context.showMessage(message: res.errorMessage ?? "Error");
            }
          } catch (e, s) {
            if (!_shouldApplyLikeResult(requestId)) {
              return;
            }
            Log.error(
              "CommentsPage",
              "Failed to update comment like for ${widget.comment.id}: $e",
              s,
            );
            context.showMessage(message: e.toString());
          } finally {
            if (_shouldApplyLikeResult(requestId)) {
              setState(() {
                isLiking = false;
              });
            }
          }
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLiking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(),
              )
            else if (isLiked)
              Icon(
                Icons.favorite,
                size: 16,
                color: context.useTextColor(Colors.red),
              )
            else
              const Icon(Icons.favorite_border, size: 16),
            const SizedBox(width: 8),
            Text(likes.toString()),
          ],
        ).padding(const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
      ),
    );
  }

  int? voteStatus;

  bool isVotingUp = false;

  bool isVotingDown = false;

  void vote(bool isUp) async {
    if (isVotingUp || isVotingDown) return;
    final requestId = ++_voteRequestId;
    setState(() {
      if (isUp) {
        isVotingUp = true;
      } else {
        isVotingDown = true;
      }
    });
    var isCancel = (isUp && voteStatus == 1) || (!isUp && voteStatus == -1);
    try {
      var res = await widget.source.voteCommentFunc!(
        widget.comic.comicId,
        widget.comic.subId,
        widget.comment.id!,
        isUp,
        isCancel,
      );
      if (!_shouldApplyVoteResult(requestId)) {
        return;
      }
      if (res.success) {
        voteStatus = resolveCommentVoteStatus(isUp: isUp, isCancel: isCancel);
        widget.comment.voteStatus = voteStatus;
        widget.comment.score = res.data ?? widget.comment.score;
      } else {
        context.showMessage(message: res.errorMessage ?? "Error");
      }
    } catch (e, s) {
      if (!_shouldApplyVoteResult(requestId)) {
        return;
      }
      Log.error(
        "CommentsPage",
        "Failed to update comment vote for ${widget.comment.id}: $e",
        s,
      );
      context.showMessage(message: e.toString());
    } finally {
      if (_shouldApplyVoteResult(requestId)) {
        setState(() {
          if (isUp) {
            isVotingUp = false;
          } else {
            isVotingDown = false;
          }
        });
      }
    }
  }

  bool _shouldApplyLikeResult(int requestId) {
    return shouldApplyCommentActionResult(
      mounted: mounted,
      requestId: requestId,
      activeRequestId: _likeRequestId,
    );
  }

  bool _shouldApplyVoteResult(int requestId) {
    return shouldApplyCommentActionResult(
      mounted: mounted,
      requestId: requestId,
      activeRequestId: _voteRequestId,
    );
  }

  Widget buildVote() {
    var upColor = context.colorScheme.outline;
    if (voteStatus == 1) {
      upColor = context.useTextColor(Colors.red);
    }
    var downColor = context.colorScheme.outline;
    if (voteStatus == -1) {
      downColor = context.useTextColor(Colors.blue);
    }

    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(
            isLoading: isVotingUp,
            icon: const Icon(Icons.arrow_upward),
            size: 18,
            color: upColor,
            onPressed: () => vote(true),
          ),
          const SizedBox(width: 4),
          Text(widget.comment.score.toString()),
          const SizedBox(width: 4),
          Button.icon(
            isLoading: isVotingDown,
            icon: const Icon(Icons.arrow_downward),
            size: 18,
            color: downColor,
            onPressed: () => vote(false),
          ),
        ],
      ),
    );
  }
}

class _CommentContent extends StatelessWidget {
  const _CommentContent({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (!text.contains('<') && !text.contains('http')) {
      return SelectableText(text);
    } else {
      return RichCommentContent(text: text);
    }
  }
}
