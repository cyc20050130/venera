part of 'reader.dart';

@visibleForTesting
bool shouldRunReaderLongPressCallback({
  required bool mounted,
  required int? lastPointer,
  required int eventPointer,
  required int fingers,
}) {
  return mounted && lastPointer == eventPointer && fingers == 1;
}

@visibleForTesting
bool shouldRunReaderPendingTapCallback({
  required bool mounted,
  required Object? currentPendingTap,
  required Object pendingTap,
}) {
  return mounted && currentPendingTap == pendingTap;
}

@visibleForTesting
bool shouldTrackReaderPointerDown(Offset position) {
  return position != Offset.zero;
}

@visibleForTesting
int readerPointerCountAfterPointerEnd(int currentCount) {
  return currentCount <= 0 ? 0 : currentCount - 1;
}

class _ReaderGestureDetector extends StatefulWidget {
  const _ReaderGestureDetector({required this.child});

  final Widget child;

  @override
  State<_ReaderGestureDetector> createState() => _ReaderGestureDetectorState();
}

class _ReaderGestureDetectorState
    extends AutomaticGlobalState<_ReaderGestureDetector> {
  late TapGestureRecognizer _tapGestureRecognizer;

  static const _kLongPressMinTime = Duration(milliseconds: 250);

  static const _kDoubleTapMaxDistanceSquared = 20.0 * 20.0;

  static const _kInteractionMoveDistanceSquared = 16.0 * 16.0;

  final _dragListeners = <_DragListener>[];

  int fingers = 0;

  late _ReaderState reader;
  _ReaderScaffoldState? _readerScaffoldState;

  bool ignoreNextTag = false;

  void ignoreNextTap() {
    ignoreNextTag = true;
  }

  void clearIgnoreNextTap() {
    ignoreNextTag = false;
  }

  @override
  void initState() {
    _tapGestureRecognizer = TapGestureRecognizer()
      ..onTapUp = onTapUp
      ..onSecondaryTapUp = (details) {
        onSecondaryTapUp(details.globalPosition);
      };
    super.initState();
    _readerScaffoldState = context.readerScaffold;
    _readerScaffoldState!._gestureDetectorState = this;
    reader = context.reader;
  }

  @override
  void dispose() {
    if (_readerScaffoldState?._gestureDetectorState == this) {
      _readerScaffoldState!._gestureDetectorState = null;
    }
    _tapGestureRecognizer.dispose();
    _dragListeners.clear();
    _previousEvent = null;
    _lastTapPointer = null;
    _lastTapMoveDistance = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (!shouldTrackReaderPointerDown(event.position)) {
          _previousEvent = null;
          return;
        }
        fingers++;
        if (ignoreNextTag) {
          ignoreNextTag = false;
          return;
        }
        _lastTapPointer = event.pointer;
        _lastTapMoveDistance = Offset.zero;
        _tapGestureRecognizer.addPointer(event);
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onStart?.call(event.position);
          }
          _dragInProgress = false;
        }
        Future.delayed(_kLongPressMinTime, () {
          if (shouldRunReaderLongPressCallback(
            mounted: mounted,
            lastPointer: _lastTapPointer,
            eventPointer: event.pointer,
            fingers: fingers,
          )) {
            if (_lastTapMoveDistance!.distanceSquared <
                    _kInteractionMoveDistanceSquared &&
                !_shouldSuppressToolbarTap) {
              onLongPressedDown(event.position);
              _longPressInProgress = true;
            } else {
              registerRecentInteraction();
              _dragInProgress = true;
              for (var dragListener in _dragListeners) {
                dragListener.onStart?.call(event.position);
                dragListener.onMove?.call(_lastTapMoveDistance!);
              }
            }
          }
        });
      },
      onPointerMove: (event) {
        if (event.pointer == _lastTapPointer) {
          _lastTapMoveDistance = event.delta + _lastTapMoveDistance!;
          if (_lastTapMoveDistance!.distanceSquared >=
              _kInteractionMoveDistanceSquared) {
            registerRecentInteraction();
          }
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onMove?.call(event.delta);
          }
        }
      },
      onPointerUp: (event) {
        fingers = readerPointerCountAfterPointerEnd(fingers);
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onEnd?.call();
          }
          registerRecentInteraction();
          _dragInProgress = false;
        }
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
      },
      onPointerCancel: (event) {
        fingers = readerPointerCountAfterPointerEnd(fingers);
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onEnd?.call();
          }
          registerRecentInteraction();
          _dragInProgress = false;
        }
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
      },
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          registerRecentInteraction();
          onMouseWheel(event.scrollDelta.dy > 0);
        }
      },
      child: widget.child,
    );
  }

  void onMouseWheel(bool forward) {
    if (HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    if (context.reader.mode.key.startsWith('gallery')) {
      if (forward) {
        if (!context.reader.toNextPage() &&
            !context.reader.isLastChapterOfGroup) {
          context.reader.toNextChapter();
        }
      } else {
        if (!context.reader.toPrevPage() &&
            !context.reader.isFirstChapterOfGroup) {
          context.reader.toPrevChapter(toLastPage: true);
        }
      }
    }
  }

  _PendingTap? _previousEvent;

  int? _lastTapPointer;

  Offset? _lastTapMoveDistance;

  DateTime? _toolbarTapSuppressedUntil;

  bool _longPressInProgress = false;

  bool _dragInProgress = false;

  bool get _enableDoubleTapToZoom => appdata.settings.getReaderSetting(
    reader.cid,
    reader.type.sourceKey,
    'enableDoubleTapToZoom',
  );

  bool get _shouldSuppressToolbarTap {
    return shouldSuppressReaderToolbarTap(_toolbarTapSuppressedUntil);
  }

  void registerRecentInteraction([
    Duration duration = kReaderToolbarTapSuppressDuration,
  ]) {
    _previousEvent = null;
    _toolbarTapSuppressedUntil = DateTime.now().add(duration);
  }

  void registerNavigationInteraction() {
    registerRecentInteraction(kReaderToolbarTapSuppressAfterNavigation);
  }

  ReaderTapNavigationAction? _getTapTurnAction(Offset location) {
    final enableTapToTurnPages = appdata.settings.getReaderSetting(
      reader.cid,
      reader.type.sourceKey,
      'enableTapToTurnPages',
    );
    final reverseTapToTurnPages = appdata.settings.getReaderSetting(
      reader.cid,
      reader.type.sourceKey,
      'reverseTapToTurnPages',
    );
    return computeReaderTapNavigationAction(
      enableTapToTurnPages: enableTapToTurnPages,
      reverseTapToTurnPages: reverseTapToTurnPages,
      modeKey: context.reader.mode.key,
      viewportSize: Size(context.width, context.height),
      location: location,
    );
  }

  void _runTapTurnAction(ReaderTapNavigationAction action) {
    registerNavigationInteraction();
    switch (action) {
      case ReaderTapNavigationAction.previous:
        context.reader.toPrevPage();
      case ReaderTapNavigationAction.next:
        context.reader.toNextPage();
    }
  }

  void onTapUp(TapUpDetails event) {
    if (event.globalPosition == Offset.zero &&
        event.localPosition == Offset.zero) {
      _previousEvent = null;
      return;
    }
    if (_longPressInProgress) {
      _longPressInProgress = false;
      return;
    }
    final location = event.globalPosition;
    if (reader.isLoading || reader._imageViewController == null) {
      _previousEvent = null;
      onTap(location);
      return;
    }
    final tapTurnAction = context.readerScaffold.isOpen
        ? null
        : _getTapTurnAction(location);
    final suppressToolbarForTap =
        !context.readerScaffold.isOpen && _shouldSuppressToolbarTap;
    if (tapTurnAction != null) {
      _previousEvent = null;
      _runTapTurnAction(tapTurnAction);
      return;
    }
    if (!_enableDoubleTapToZoom) {
      onTap(location, suppressToolbar: suppressToolbarForTap);
      return;
    }
    final previousTap = _previousEvent;
    final previousLocation = previousTap?.details.globalPosition;
    if (previousLocation != null) {
      if ((location - previousLocation).distanceSquared <
          _kDoubleTapMaxDistanceSquared) {
        onDoubleTap(location);
        _previousEvent = null;
        return;
      } else {
        onTap(previousLocation, suppressToolbar: previousTap!.suppressToolbar);
      }
    }
    final pendingTap = _PendingTap(
      details: event,
      suppressToolbar: suppressToolbarForTap,
    );
    _previousEvent = pendingTap;
    Future.delayed(kReaderDoubleTapMaxTime, () {
      if (shouldRunReaderPendingTapCallback(
        mounted: mounted,
        currentPendingTap: _previousEvent,
        pendingTap: pendingTap,
      )) {
        onTap(location, suppressToolbar: pendingTap.suppressToolbar);
        _previousEvent = null;
      }
    });
  }

  void onTap(Offset location, {bool suppressToolbar = false}) {
    final shouldOpenToolbar = shouldOpenReaderToolbar(
      tapHandledByImageView:
          reader._imageViewController?.handleOnTap(location) ?? false,
      isToolbarOpen: context.readerScaffold.isOpen,
      isOnChapterCommentsPage: reader.isOnChapterCommentsPage,
      suppressToolbarFromTapUp: suppressToolbar,
      suppressToolbarNow: _shouldSuppressToolbarTap,
    );
    if (shouldOpenToolbar) {
      context.readerScaffold.openOrClose();
    }
  }

  void onDoubleTap(Offset location) {
    registerRecentInteraction();
    context.reader._imageViewController?.handleDoubleTap(location);
  }

  void onSecondaryTapUp(Offset location) {
    showMenuX(context, location, [
      MenuEntry(
        icon: Icons.settings,
        text: "Settings".tl,
        onClick: () {
          context.readerScaffold.openSetting();
        },
      ),
      MenuEntry(
        icon: Icons.menu,
        text: "Chapters".tl,
        onClick: () {
          context.readerScaffold.openChapterDrawer();
        },
      ),
      MenuEntry(
        icon: Icons.fullscreen,
        text: "Fullscreen".tl,
        onClick: () {
          context.reader.fullscreen();
        },
      ),
      MenuEntry(
        icon: Icons.exit_to_app,
        text: "Exit".tl,
        onClick: () {
          context.pop();
        },
      ),
      if (App.isDesktop && !reader.isLoading)
        MenuEntry(
          icon: Icons.copy,
          text: "Copy Image".tl,
          onClick: () => copyImage(location),
        ),
      if (!reader.isLoading)
        MenuEntry(
          icon: Icons.download_outlined,
          text: "Save Image".tl,
          onClick: () => saveImage(location),
        ),
    ]);
  }

  void onLongPressedUp(Offset location) {
    registerRecentInteraction();
    context.reader._imageViewController?.handleLongPressUp(location);
  }

  void onLongPressedDown(Offset location) {
    registerRecentInteraction();
    context.reader._imageViewController?.handleLongPressDown(location);
  }

  void addDragListener(_DragListener listener) {
    _dragListeners.add(listener);
  }

  void removeDragListener(_DragListener listener) {
    _dragListeners.remove(listener);
  }

  @override
  Object? get key => "reader_gesture";

  void copyImage(Offset location) async {
    var controller = reader._imageViewController;
    if (controller == null) {
      return;
    }
    var image = await controller.getImageByOffset(location);
    if (!mounted) {
      return;
    }
    if (image != null) {
      writeImageToClipboard(image);
    } else {
      context.showMessage(message: "No Image");
    }
  }

  void saveImage(Offset location) async {
    var controller = reader._imageViewController;
    if (controller == null) {
      return;
    }
    var image = await controller.getImageByOffset(location);
    if (!mounted) {
      return;
    }
    if (image != null) {
      var filetype = detectFileType(image);
      saveFile(filename: "image${filetype.ext}", data: image);
    } else {
      context.showMessage(message: "No Image");
    }
  }
}

class _DragListener {
  void Function(Offset point)? onStart;
  void Function(Offset offset)? onMove;
  void Function()? onEnd;

  _DragListener({this.onMove, this.onEnd});
}

class _PendingTap {
  final TapUpDetails details;
  final bool suppressToolbar;

  const _PendingTap({required this.details, required this.suppressToolbar});
}
