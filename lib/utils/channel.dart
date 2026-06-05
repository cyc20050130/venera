import 'dart:async';
import 'dart:collection';

class Channel<T> {
  final Queue<T> _queue;

  final int size;

  Channel(this.size) : _queue = Queue<T>() {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'must be greater than zero');
    }
  }

  Completer<void>? _releaseCompleter;

  Completer<void>? _pushCompleter;

  var currentSize = 0;

  var isClosed = false;

  Future<void> push(T item) async {
    while (currentSize >= size && !isClosed) {
      _releaseCompleter ??= Completer();
      await _releaseCompleter!.future;
    }
    if (isClosed) {
      return;
    }
    _queue.addLast(item);
    currentSize++;
    _completePushWaiter();
  }

  void _completePushWaiter() {
    final completer = _pushCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _pushCompleter = null;
  }

  void _completeReleaseWaiter() {
    final completer = _releaseCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _releaseCompleter = null;
  }

  Future<T?> pop() async {
    while (_queue.isEmpty) {
      if (isClosed) {
        return null;
      }
      _pushCompleter ??= Completer();
      await _pushCompleter!.future;
    }
    var item = _queue.removeFirst();
    currentSize--;
    if (_releaseCompleter != null && currentSize < size) {
      _completeReleaseWaiter();
    }
    return item;
  }

  void close() {
    isClosed = true;
    _completePushWaiter();
    _completeReleaseWaiter();
  }
}
