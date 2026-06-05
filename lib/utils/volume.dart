import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:venera/foundation/log.dart';

class VolumeListener {
  static const channel = EventChannel('venera/volume');

  void Function()? onUp;

  void Function()? onDown;

  VolumeListener({this.onUp, this.onDown});

  StreamSubscription<dynamic>? stream;

  void listen() {
    if (stream != null) {
      return;
    }
    listenTo(channel.receiveBroadcastStream());
  }

  @visibleForTesting
  void listenTo(Stream<dynamic> events) {
    if (stream != null) {
      return;
    }
    stream = events.listen(
      onEvent,
      onError: (Object error, StackTrace stackTrace) {
        Log.error('Volume stream failed', error, stackTrace);
      },
    );
  }

  void onEvent(event) {
    if (event == 1) {
      onUp?.call();
    } else if (event == 2) {
      onDown?.call();
    }
  }

  void cancel() {
    stream?.cancel();
    stream = null;
  }
}
