import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/aggregated_search_page.dart';

StreamSubscription<dynamic>? _textShareSubscription;

/// Handle text share event.
/// App will navigate to [AggregatedSearchPage] with the shared text as keyword.
void handleTextShare() {
  if (_textShareSubscription != null) {
    return;
  }
  var channel = EventChannel('venera/text_share');
  _textShareSubscription = channel.receiveBroadcastStream().listen(
    (event) async {
      try {
        if (event is! String || event.trim().isEmpty) {
          return;
        }
        final context = await App.waitForMainNavigatorContext();
        if (context == null || !context.mounted) {
          return;
        }
        context.to(() => AggregatedSearchPage(keyword: event.trim()));
      } catch (e, s) {
        Log.error('Text share handling failed', e, s);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      Log.error('Text share stream failed', error, stackTrace);
    },
  );
}

@visibleForTesting
bool get hasTextShareSubscriptionForTesting => _textShareSubscription != null;

@visibleForTesting
Future<void> resetTextShareForTesting() async {
  await _textShareSubscription?.cancel();
  _textShareSubscription = null;
}
