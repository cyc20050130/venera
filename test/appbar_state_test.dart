import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:flutter/material.dart';

void main() {
  test(
    'normalizeAppTabBarStorageIndex tolerates stale page storage values',
    () {
      expect(normalizeAppTabBarStorageIndex(2), 2);
      expect(normalizeAppTabBarStorageIndex('3'), 3);
      expect(normalizeAppTabBarStorageIndex(-1), isNull);
      expect(normalizeAppTabBarStorageIndex('bad'), isNull);
      expect(normalizeAppTabBarStorageIndex(null), isNull);
    },
  );

  test(
    'resizeAppTabBarKeys preserves existing keys and matches tab length',
    () {
      final first = GlobalKey();
      final second = GlobalKey();

      final expanded = resizeAppTabBarKeys([first, second], 4);
      expect(expanded, hasLength(4));
      expect(expanded[0], same(first));
      expect(expanded[1], same(second));
      expect(expanded[2], isNot(same(first)));
      expect(expanded[3], isNot(same(second)));

      final shrunk = resizeAppTabBarKeys(expanded, 1);
      expect(shrunk, hasLength(1));
      expect(shrunk.single, same(first));
    },
  );
}
