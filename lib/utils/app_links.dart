import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/ext.dart';

StreamSubscription<Uri>? _appLinksSubscription;

void handleLinks() {
  if (_appLinksSubscription != null) {
    return;
  }
  final appLinks = AppLinks();
  _appLinksSubscription = appLinks.uriLinkStream.listen(
    (uri) {
      unawaited(handleAppLink(uri));
    },
    onError: (Object error, StackTrace stackTrace) {
      Log.error('App link stream failed', error, stackTrace);
    },
  );
}

@visibleForTesting
bool get hasAppLinksSubscriptionForTesting => _appLinksSubscription != null;

@visibleForTesting
Future<void> resetAppLinksForTesting() async {
  await _appLinksSubscription?.cancel();
  _appLinksSubscription = null;
}

Future<bool> handleAppLink(Uri uri) async {
  try {
    final source = comicSourceForAppLink(uri);
    if (source == null) {
      return false;
    }
    var id = source.linkHandler!.linkToId(uri.toString());
    if (id != null) {
      final context = await App.waitForMainNavigatorContext();
      if (context == null || !context.mounted) {
        return false;
      }
      context.to(() {
        return ComicPage(id: id, sourceKey: source.key);
      });
      return true;
    }
    return false;
  } catch (e, s) {
    Log.error('App link handling failed', e, s);
    return false;
  }
}

Uri? parseSafeLinkUri(String text) {
  final candidate = text.trim();
  if (!candidate.isURL || _hasMalformedPercentEncoding(candidate)) {
    return null;
  }
  return Uri.tryParse(candidate);
}

bool _hasMalformedPercentEncoding(String value) {
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) != 0x25) {
      continue;
    }
    if (i + 2 >= value.length ||
        !_isHexCodeUnit(value.codeUnitAt(i + 1)) ||
        !_isHexCodeUnit(value.codeUnitAt(i + 2))) {
      return true;
    }
  }
  return false;
}

bool _isHexCodeUnit(int codeUnit) {
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x46) ||
      (codeUnit >= 0x61 && codeUnit <= 0x66);
}

@visibleForTesting
ComicSource? comicSourceForAppLink(Uri uri) {
  for (var source in ComicSource.all()) {
    if (source.linkHandler != null) {
      if (source.linkHandler!.domains.contains(uri.host)) {
        return source;
      }
    }
  }
  return null;
}

bool canHandleAppLinkText(String text) {
  final uri = parseSafeLinkUri(text);
  return uri != null && comicSourceForAppLink(uri) != null;
}
