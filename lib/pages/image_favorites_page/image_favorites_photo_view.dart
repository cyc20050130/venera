part of 'image_favorites_page.dart';

@visibleForTesting
bool shouldApplyImageFavoriteMenuActionResult({
  required bool mounted,
  required int requestId,
  required int activeRequestId,
  required int page,
  required int currentPage,
}) {
  return mounted && requestId == activeRequestId && page == currentPage;
}

@visibleForTesting
bool isValidImageFavoriteMenuPage({
  required int page,
  required int imageCount,
}) {
  return page >= 0 && page < imageCount;
}

class ImageFavoritesPhotoView extends StatefulWidget {
  const ImageFavoritesPhotoView({
    super.key,
    required this.comic,
    required this.imageFavorite,
  });

  @visibleForTesting
  static PageController Function(int initialPage)? debugPageControllerFactory;

  final ImageFavoritesComic comic;
  final ImageFavorite imageFavorite;

  @override
  State<ImageFavoritesPhotoView> createState() =>
      _ImageFavoritesPhotoViewState();
}

class _ImageFavoritesPhotoViewState extends State<ImageFavoritesPhotoView> {
  late PageController controller;
  Map<ImageFavorite, bool> cancelImageFavorites = {};

  var images = <ImageFavorite>[];

  int currentPage = 0;

  bool isAppBarShow = false;

  int _saveImageRequestId = 0;

  @override
  void initState() {
    var current = 0;
    for (var ep in widget.comic.imageFavoritesEp) {
      for (var image in ep.imageFavorites) {
        images.add(image);
        if (image == widget.imageFavorite) {
          current = images.length - 1;
        }
      }
    }
    currentPage = current;
    controller =
        ImageFavoritesPhotoView.debugPageControllerFactory?.call(current) ??
        PageController(initialPage: current);
    super.initState();
  }

  @override
  void dispose() {
    _saveImageRequestId++;
    controller.dispose();
    super.dispose();
  }

  void onPop() {
    List<ImageFavorite> tempList = cancelImageFavorites.entries
        .where((e) => e.value == true)
        .map((e) => e.key)
        .toList();
    if (tempList.isNotEmpty) {
      ImageFavoriteManager().deleteImageFavorite(tempList);
      showToast(
        message: "Delete @a images".tlParams({'a': tempList.length}),
        context: context,
      );
    }
  }

  PhotoViewGalleryPageOptions _buildItem(BuildContext context, int index) {
    var image = images[index];
    return PhotoViewGalleryPageOptions(
      // 图片加载器 支持本地、网络
      imageProvider: ImageFavoritesProvider(image),
      // 初始化大小 全部展示
      minScale: PhotoViewComputedScale.contained * 1.0,
      maxScale: PhotoViewComputedScale.covered * 10.0,
      onTapUp: (context, details, controllerValue) {
        setState(() {
          isAppBarShow = !isAppBarShow;
        });
      },
      heroAttributes: PhotoViewHeroAttributes(
        tag: "${image.sourceKey}${image.ep}${image.page}",
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) {
          onPop();
        }
      },
      child: Listener(
        onPointerSignal: (event) {
          if (HardwareKeyboard.instance.isControlPressed) {
            return;
          }
          if (event is PointerScrollEvent) {
            if (event.scrollDelta.dy > 0) {
              if (controller.page! >= images.length - 1) {
                return;
              }
              controller.nextPage(
                duration: Duration(milliseconds: 180),
                curve: Curves.ease,
              );
            } else {
              if (controller.page! <= 0) {
                return;
              }
              controller.previousPage(
                duration: Duration(milliseconds: 180),
                curve: Curves.ease,
              );
            }
          }
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: PhotoViewGallery.builder(
                backgroundDecoration: BoxDecoration(
                  color: context.colorScheme.surface,
                ),
                builder: _buildItem,
                itemCount: images.length,
                loadingBuilder: (context, event) => Center(
                  child: SizedBox(
                    width: 20.0,
                    height: 20.0,
                    child: CircularProgressIndicator(
                      backgroundColor: context.colorScheme.surfaceContainerHigh,
                      value: event == null || event.expectedTotalBytes == null
                          ? null
                          : event.cumulativeBytesLoaded /
                                event.expectedTotalBytes!,
                    ),
                  ),
                ),
                pageController: controller,
                onPageChanged: (index) {
                  setState(() {
                    currentPage = index;
                  });
                },
              ),
            ),
            buildPageInfo(),
            AnimatedPositioned(
              top: isAppBarShow ? 0 : -(context.padding.top + 52),
              left: 0,
              right: 0,
              duration: Duration(milliseconds: 180),
              child: buildAppBar(),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildPageInfo() {
    var text = "${currentPage + 1}/${images.length}";
    return Positioned(
      height: 40,
      left: 0,
      right: 0,
      bottom: 0,
      child: Center(
        child: Stack(
          children: [
            Text(
              text,
              style: TextStyle(
                fontSize: 14,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4
                  ..color = context.colorScheme.onInverseSurface,
              ),
            ),
            Text(text),
          ],
        ),
      ),
    );
  }

  Widget buildAppBar() {
    return Material(
      color: context.colorScheme.surface.toOpacity(0.72),
      child: BlurEffect(
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: context.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.close),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.comic.title, style: TextStyle(fontSize: 18)),
              ),
              IconButton(icon: Icon(Icons.more_vert), onPressed: showMenu),
              const SizedBox(width: 8),
            ],
          ),
        ).paddingTop(context.padding.top),
      ),
    );
  }

  void showMenu() {
    showMenuX(context, Offset(context.width, context.padding.top), [
      MenuEntry(
        icon: Icons.image_outlined,
        text: "Save Image".tl,
        onClick: () async {
          final page = currentPage;
          if (!isValidImageFavoriteMenuPage(
            page: page,
            imageCount: images.length,
          )) {
            return;
          }
          final requestId = ++_saveImageRequestId;
          final temp = images[page];
          try {
            final imageProvider = ImageFavoritesProvider(temp);
            final data = await imageProvider.load(null, null);
            if (!_shouldApplySaveImageResult(requestId, page)) {
              return;
            }
            final fileType = detectFileType(data);
            final fileName = "${page + 1}.${fileType.ext}";
            await saveFile(filename: fileName, data: data);
          } catch (e, s) {
            if (_shouldApplySaveImageResult(requestId, page)) {
              Log.error("Image Favorites", "Failed to save image: $e", s);
            }
          }
        },
      ),
      MenuEntry(
        icon: Icons.menu_book_outlined,
        text: "Read".tl,
        onClick: () async {
          final current = currentPage;
          if (!isValidImageFavoriteMenuPage(
            page: current,
            imageCount: images.length,
          )) {
            return;
          }
          var comic = widget.comic;
          var image = images[current];
          var ep = image.ep;
          var page = image.page;
          App.rootContext.to(
            () => ReaderWithLoading(
              id: comic.id,
              sourceKey: comic.sourceKey,
              initialEp: ep,
              initialPage: page,
            ),
          );
        },
      ),
    ]);
  }

  bool _shouldApplySaveImageResult(int requestId, int page) {
    return shouldApplyImageFavoriteMenuActionResult(
      mounted: mounted,
      requestId: requestId,
      activeRequestId: _saveImageRequestId,
      page: page,
      currentPage: currentPage,
    );
  }
}
