import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/home_page.dart';

void main() {
  test('home refresh debouncer coalesces rapid refresh requests', () async {
    final debouncer = HomeRefreshDebouncer(
      delay: const Duration(milliseconds: 40),
    );
    var runs = 0;

    debouncer.schedule(() {
      runs++;
    });
    debouncer.schedule(() {
      runs++;
    });

    await Future<void>.delayed(const Duration(milliseconds: 70));

    expect(runs, 1);
    debouncer.dispose();
  });
}
