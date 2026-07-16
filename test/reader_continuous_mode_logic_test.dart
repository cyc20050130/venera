import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  test(
    'continuous reader selects the leading visible item, not iterable first',
    () {
      const positions = <ItemPosition>[
        ItemPosition(index: 6, itemLeadingEdge: 0.35, itemTrailingEdge: 0.9),
        ItemPosition(index: 4, itemLeadingEdge: -0.4, itemTrailingEdge: -0.1),
        ItemPosition(index: 5, itemLeadingEdge: -0.1, itemTrailingEdge: 0.35),
      ];

      expect(
        resolveContinuousReaderLeadingPage(positions: positions, maxPage: 20),
        5,
      );
    },
  );

  test(
    'continuous reader clamps sentinel items to the readable page range',
    () {
      expect(
        resolveContinuousReaderLeadingPage(
          positions: const [
            ItemPosition(index: 0, itemLeadingEdge: 0, itemTrailingEdge: 0.2),
          ],
          maxPage: 8,
        ),
        1,
      );
      expect(
        resolveContinuousReaderLeadingPage(
          positions: const [
            ItemPosition(index: 9, itemLeadingEdge: 0.8, itemTrailingEdge: 1),
          ],
          maxPage: 8,
        ),
        8,
      );
    },
  );

  test('continuous reader ignores items fully before the viewport', () {
    expect(
      resolveContinuousReaderLeadingPage(
        positions: const [
          ItemPosition(index: 2, itemLeadingEdge: -1, itemTrailingEdge: 0),
        ],
        maxPage: 8,
      ),
      isNull,
    );
    expect(
      resolveContinuousReaderLeadingPage(positions: const [], maxPage: 8),
      isNull,
    );
  });
}
