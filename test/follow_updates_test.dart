import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/pages/follow_updates_page.dart';

void main() {
  test('compareFollowUpdateTime sorts newest dates first', () {
    final values = ['2026-05-01', '2026-05-22', '2025-12-31'];

    values.sort(compareFollowUpdateTime);

    expect(values, ['2026-05-22', '2026-05-01', '2025-12-31']);
  });

  test('compareFollowUpdateTime keeps null and malformed values last', () {
    final values = <String?>['bad', null, '2026-05-22', ''];

    values.sort(compareFollowUpdateTime);

    expect(values.take(1), ['2026-05-22']);
    expect(values.skip(1), containsAllInOrder(['bad', null, '']));
  });

  test('parseFollowUpdateTimeParts rejects malformed values', () {
    expect(parseFollowUpdateTimeParts('2026-05-22'), [2026, 5, 22]);
    expect(parseFollowUpdateTimeParts('2026-x-22'), isNull);
    expect(parseFollowUpdateTimeParts(null), isNull);
  });

  test('resolveFollowUpdatesFolder accepts only non-empty strings', () {
    expect(resolveFollowUpdatesFolder('Folder'), 'Folder');
    expect(resolveFollowUpdatesFolder(''), isNull);
    expect(resolveFollowUpdatesFolder(1), isNull);
    expect(resolveFollowUpdatesFolder(null), isNull);
  });

  test('followUpdateProgressRatio clamps invalid progress values', () {
    expect(followUpdateProgressRatio(UpdateProgress(0, 0, 0, 0)), isNull);
    expect(followUpdateProgressRatio(UpdateProgress(10, -1, 0, 0)), 0);
    expect(followUpdateProgressRatio(UpdateProgress(10, 11, 0, 0)), 1);
    expect(followUpdateProgressRatio(UpdateProgress(10, 5, 0, 0)), 0.5);
  });

  test('follow update checker stops waiting for data sync after cancel', () {
    expect(
      shouldWaitForDataSyncBeforeFollowUpdate(
        isDownloading: true,
        isCanceled: false,
      ),
      isTrue,
    );
    expect(
      shouldWaitForDataSyncBeforeFollowUpdate(
        isDownloading: true,
        isCanceled: true,
      ),
      isFalse,
    );
    expect(
      shouldWaitForDataSyncBeforeFollowUpdate(
        isDownloading: false,
        isCanceled: false,
      ),
      isFalse,
    );
  });

  test(
    'follow update action result only applies to active mounted request',
    () {
      expect(
        shouldApplyFollowUpdateActionResult(
          mounted: true,
          requestId: 2,
          activeRequestId: 2,
        ),
        isTrue,
      );
      expect(
        shouldApplyFollowUpdateActionResult(
          mounted: false,
          requestId: 2,
          activeRequestId: 2,
        ),
        isFalse,
      );
      expect(
        shouldApplyFollowUpdateActionResult(
          mounted: true,
          requestId: 1,
          activeRequestId: 2,
        ),
        isFalse,
      );
    },
  );

  test('FollowUpdatesService reset cancels periodic checker', () {
    FollowUpdatesService.resetForTesting();

    FollowUpdatesService.initChecker(
      scheduleInitialCheck: false,
      listenToDataSync: false,
    );
    expect(FollowUpdatesService.isCheckerInitialized, isTrue);
    expect(FollowUpdatesService.hasScheduledChecker, isTrue);

    FollowUpdatesService.initChecker(
      scheduleInitialCheck: false,
      listenToDataSync: false,
    );
    expect(FollowUpdatesService.hasScheduledChecker, isTrue);

    FollowUpdatesService.resetForTesting();
    expect(FollowUpdatesService.isCheckerInitialized, isFalse);
    expect(FollowUpdatesService.hasScheduledChecker, isFalse);
  });
}
