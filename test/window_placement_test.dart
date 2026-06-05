import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/window_frame.dart';

void main() {
  test('stored window placement rejects malformed geometry', () {
    expect(
      WindowPlacement.normalizeStoredPlacement('bad').rect,
      WindowPlacement.defaultPlacement.rect,
    );
    expect(
      WindowPlacement.normalizeStoredPlacement({
        'x': -1,
        'y': 1,
        'width': 900,
        'height': 600,
      }).rect,
      WindowPlacement.defaultPlacement.rect,
    );
    expect(
      WindowPlacement.normalizeStoredPlacement({
        'x': 1,
        'y': 1,
        'width': 0,
        'height': 600,
      }).rect,
      WindowPlacement.defaultPlacement.rect,
    );
    expect(
      WindowPlacement.normalizeStoredPlacement({
        'x': double.nan,
        'y': 1,
        'width': 900,
        'height': 600,
      }).rect,
      WindowPlacement.defaultPlacement.rect,
    );
  });

  test('stored window placement accepts numeric strings safely', () {
    final placement = WindowPlacement.normalizeStoredPlacement({
      'x': '12',
      'y': '34',
      'width': '900.5',
      'height': '600',
      'isMaximized': true,
    });

    expect(placement.rect.left, 12);
    expect(placement.rect.top, 34);
    expect(placement.rect.width, 900.5);
    expect(placement.rect.height, 600);
    expect(placement.isMaximized, isTrue);
  });

  test('window placement change detection includes maximized state', () {
    const placement = WindowPlacement.defaultPlacement;
    expect(WindowPlacement.isPlacementChanged(placement, placement), isFalse);
    expect(
      WindowPlacement.isPlacementChanged(
        placement,
        const WindowPlacement(Rect.fromLTWH(10, 10, 900, 600), true),
      ),
      isTrue,
    );
    expect(
      WindowPlacement.isPlacementChanged(
        placement,
        const WindowPlacement(Rect.fromLTWH(11, 10, 900, 600), false),
      ),
      isTrue,
    );
  });
}
