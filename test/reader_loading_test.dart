import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  test('requested chapter group overrides history group when opening reader', () {
    expect(
      resolveReaderInitialChapterGroup(
        requestedGroup: 3,
        historyGroup: 1,
      ),
      3,
    );
  });

  test('history group remains the fallback when request group is absent', () {
    expect(
      resolveReaderInitialChapterGroup(
        requestedGroup: null,
        historyGroup: 2,
      ),
      2,
    );
  });
}
