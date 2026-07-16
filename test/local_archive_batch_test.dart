import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/local_archive.dart';
import 'package:venera/foundation/local_archive_batch.dart';

void main() {
  test(
    'batch runner bounds concurrency and reports monotonic progress',
    () async {
      var active = 0;
      var maxActive = 0;
      final release = Completer<void>();
      final progress = <double>[];
      final token = LocalArchiveCancellationToken();
      final tasks = List.generate(
        4,
        (index) => LocalArchiveBatchTask<int>(
          key: '$index',
          run: (token, report) async {
            active++;
            maxActive = active > maxActive ? active : maxActive;
            report(
              const LocalArchiveProgress(
                operation: LocalArchiveOperation.compress,
                completedFiles: 1,
                totalFiles: 2,
              ),
            );
            await release.future;
            active--;
            return index;
          },
        ),
      );

      final future = runLocalArchiveBatch(
        tasks: tasks,
        maxConcurrency: 2,
        cancellationToken: token,
        onProgress: (value) => progress.add(value.fraction),
      );
      await _waitUntil(() => active == 2);
      expect(maxActive, 2);
      release.complete();

      final result = await future;
      expect(result.values, hasLength(4));
      expect(result.failures, isEmpty);
      expect(result.cancelled, isFalse);
      expect(progress.last, 1);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
    },
  );

  test('task failures are isolated from the rest of the batch', () async {
    final result = await runLocalArchiveBatch<int>(
      tasks: [
        LocalArchiveBatchTask(
          key: 'bad',
          run: (_, _) async => throw StateError('boom'),
        ),
        LocalArchiveBatchTask(key: 'good', run: (_, _) async => 7),
      ],
      maxConcurrency: 2,
      cancellationToken: LocalArchiveCancellationToken(),
    );

    expect(result.values, {'good': 7});
    expect(result.failures['bad']?.error, isA<StateError>());
    expect(result.completedItems, 2);
  });

  test('cancellation prevents queued tasks from starting', () async {
    final token = LocalArchiveCancellationToken();
    var started = 0;
    final tasks = List.generate(
      4,
      (index) => LocalArchiveBatchTask<int>(
        key: '$index',
        run: (token, _) async {
          started++;
          token.cancel();
          token.throwIfCancelled();
          return index;
        },
      ),
    );

    final result = await runLocalArchiveBatch(
      tasks: tasks,
      maxConcurrency: 1,
      cancellationToken: token,
    );

    expect(result.cancelled, isTrue);
    expect(started, 1);
    expect(result.startedItems, 1);
    expect(result.values, isEmpty);
  });

  test('duplicate task keys are rejected', () async {
    await expectLater(
      runLocalArchiveBatch<int>(
        tasks: [
          LocalArchiveBatchTask(key: 'same', run: (_, _) async => 1),
          LocalArchiveBatchTask(key: 'same', run: (_, _) async => 2),
        ],
        maxConcurrency: 1,
        cancellationToken: LocalArchiveCancellationToken(),
      ),
      throwsArgumentError,
    );
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for batch state');
}
