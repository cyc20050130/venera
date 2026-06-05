import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/ranking_page.dart';

void main() {
  test('defaultRankingOptionValue tolerates empty options', () {
    expect(defaultRankingOptionValue({}), isNull);
    expect(
      defaultRankingOptionValue({'daily': 'Daily', 'weekly': 'Weekly'}),
      'daily',
    );
  });
}
