import 'dart:convert';

import 'package:flutter/services.dart';

abstract class OpenCC {
  static Map<int, int>? _s2t;
  static Map<int, int>? _t2s;

  static Future<void> init() async {
    if (_s2t != null && _t2s != null) {
      return;
    }
    var data = await rootBundle.load("assets/opencc.txt");
    var txt = utf8.decode(data.buffer.asUint8List());
    final s2t = <int, int>{};
    final t2s = <int, int>{};
    for (var line in txt.split('\n')) {
      line = line.trimRight();
      final runes = line.runes.toList(growable: false);
      if (line.isEmpty || line.startsWith('#') || runes.length != 2) continue;
      var s = runes[0];
      var t = runes[1];
      s2t[s] = t;
      t2s[t] = s;
    }
    _s2t = s2t;
    _t2s = t2s;
  }

  static bool hasChineseSimplified(String text) {
    final s2t = _s2t;
    if (s2t == null) {
      return false;
    }
    for (var rune in text.runes) {
      if (s2t.containsKey(rune)) {
        return true;
      }
    }
    return false;
  }

  static bool hasChineseTraditional(String text) {
    final t2s = _t2s;
    if (t2s == null) {
      return false;
    }
    for (var rune in text.runes) {
      if (t2s.containsKey(rune)) {
        return true;
      }
    }
    return false;
  }

  static String simplifiedToTraditional(String text) {
    final s2t = _s2t;
    if (s2t == null) {
      return text;
    }
    var sb = StringBuffer();
    for (var rune in text.runes) {
      final converted = s2t[rune];
      if (converted != null) {
        sb.write(String.fromCharCodes([converted]));
      } else {
        sb.write(String.fromCharCodes([rune]));
      }
    }
    return sb.toString();
  }

  static String traditionalToSimplified(String text) {
    final t2s = _t2s;
    if (t2s == null) {
      return text;
    }
    var sb = StringBuffer();
    for (var rune in text.runes) {
      final converted = t2s[rune];
      if (converted != null) {
        sb.write(String.fromCharCodes([converted]));
      } else {
        sb.write(String.fromCharCodes([rune]));
      }
    }
    return sb.toString();
  }
}
