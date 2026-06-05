import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/main_page.dart';

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

  test('resume data sync only runs after the idle interval', () {
    final lastCheck = DateTime(2026, 6, 3, 20);

    expect(
      shouldRunResumeDataSync(
        state: AppLifecycleState.paused,
        now: lastCheck.add(const Duration(minutes: 30)),
        lastCheck: lastCheck,
      ),
      isFalse,
    );

    expect(
      shouldRunResumeDataSync(
        state: AppLifecycleState.resumed,
        now: lastCheck.add(const Duration(minutes: 5)),
        lastCheck: lastCheck,
      ),
      isFalse,
    );

    expect(
      shouldRunResumeDataSync(
        state: AppLifecycleState.resumed,
        now: lastCheck.add(const Duration(minutes: 11)),
        lastCheck: lastCheck,
      ),
      isTrue,
    );
  });

  test('main page initial index rejects stale synced page values', () {
    expect(resolveInitialMainPageIndex('2', 4), 2);
    expect(resolveInitialMainPageIndex(3, 4), 3);
    expect(resolveInitialMainPageIndex('bad', 4), 0);
    expect(resolveInitialMainPageIndex(-1, 4), 0);
    expect(resolveInitialMainPageIndex('4', 4), 0);
    expect(resolveInitialMainPageIndex(99, 4), 0);
    expect(resolveInitialMainPageIndex(0, 0), 0);
  });
}
