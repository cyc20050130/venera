import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/local_archive.dart';

typedef LocalArchiveBatchTaskRunner<T> =
    Future<T> Function(
      LocalArchiveCancellationToken cancellationToken,
      LocalArchiveProgressCallback onProgress,
    );

@immutable
final class LocalArchiveBatchTask<T> {
  const LocalArchiveBatchTask({required this.key, required this.run});

  final String key;
  final LocalArchiveBatchTaskRunner<T> run;
}

@immutable
final class LocalArchiveBatchProgress {
  const LocalArchiveBatchProgress({
    required this.totalItems,
    required this.startedItems,
    required this.completedItems,
    required this.activeItems,
    required this.fraction,
    this.latestProgress,
  });

  final int totalItems;
  final int startedItems;
  final int completedItems;
  final int activeItems;
  final double fraction;
  final LocalArchiveProgress? latestProgress;
}

@immutable
final class LocalArchiveBatchFailure {
  const LocalArchiveBatchFailure({
    required this.error,
    required this.stackTrace,
  });

  final Object error;
  final StackTrace stackTrace;
}

@immutable
final class LocalArchiveBatchResult<T> {
  const LocalArchiveBatchResult({
    required this.values,
    required this.failures,
    required this.cancelled,
    required this.startedItems,
  });

  final Map<String, T> values;
  final Map<String, LocalArchiveBatchFailure> failures;
  final bool cancelled;
  final int startedItems;

  int get completedItems => values.length + failures.length;
}

/// Executes independent archive operations with bounded concurrency.
///
/// The archive service still serializes work for the same comic and applies
/// its platform-wide heavy-I/O semaphore. This scheduler makes that existing
/// capacity available to batch UI without spawning an unbounded Future list.
Future<LocalArchiveBatchResult<T>> runLocalArchiveBatch<T>({
  required List<LocalArchiveBatchTask<T>> tasks,
  required int maxConcurrency,
  required LocalArchiveCancellationToken cancellationToken,
  void Function(LocalArchiveBatchProgress progress)? onProgress,
}) async {
  if (maxConcurrency <= 0) {
    throw ArgumentError.value(
      maxConcurrency,
      'maxConcurrency',
      'Must be greater than zero.',
    );
  }
  if (tasks.isEmpty) {
    return LocalArchiveBatchResult<T>(
      values: <String, T>{},
      failures: const <String, LocalArchiveBatchFailure>{},
      cancelled: false,
      startedItems: 0,
    );
  }
  final keys = <String>{};
  for (final task in tasks) {
    if (!keys.add(task.key)) {
      throw ArgumentError.value(task.key, 'tasks', 'Duplicate task key');
    }
  }

  final values = <String, T>{};
  final failures = <String, LocalArchiveBatchFailure>{};
  final itemProgress = <String, double>{};
  final activeKeys = <String>{};
  var nextIndex = 0;
  var startedItems = 0;
  var completedItems = 0;
  var cancelled = cancellationToken.isCancelled;
  var lastFraction = 0.0;
  LocalArchiveProgress? latestProgress;

  void emit() {
    final runningFraction = activeKeys.fold<double>(
      0,
      (sum, key) => sum + (itemProgress[key] ?? 0),
    );
    final calculated = tasks.isEmpty
        ? 1.0
        : (completedItems + runningFraction) / tasks.length;
    final fraction = calculated.clamp(lastFraction, 1.0);
    lastFraction = fraction;
    onProgress?.call(
      LocalArchiveBatchProgress(
        totalItems: tasks.length,
        startedItems: startedItems,
        completedItems: completedItems,
        activeItems: activeKeys.length,
        fraction: fraction,
        latestProgress: latestProgress,
      ),
    );
  }

  Future<void> worker() async {
    while (!cancellationToken.isCancelled) {
      final index = nextIndex;
      if (index >= tasks.length) return;
      nextIndex++;
      final task = tasks[index];
      startedItems++;
      activeKeys.add(task.key);
      itemProgress[task.key] = 0;
      emit();
      try {
        final value = await task.run(cancellationToken, (progress) {
          if (cancellationToken.isCancelled) return;
          latestProgress = progress;
          final current = itemProgress[task.key] ?? 0;
          itemProgress[task.key] = localArchiveOverallProgress(
            progress,
          ).clamp(current, 1.0);
          emit();
        });
        values[task.key] = value;
      } on LocalArchiveCancelledException {
        cancelled = true;
        cancellationToken.cancel();
      } catch (error, stackTrace) {
        failures[task.key] = LocalArchiveBatchFailure(
          error: error,
          stackTrace: stackTrace,
        );
      } finally {
        activeKeys.remove(task.key);
        itemProgress.remove(task.key);
        completedItems++;
        emit();
      }
    }
    cancelled = true;
  }

  emit();
  final workerCount = maxConcurrency.clamp(1, tasks.length);
  await Future.wait(List.generate(workerCount, (_) => worker()));
  cancelled = cancelled || cancellationToken.isCancelled;
  return LocalArchiveBatchResult<T>(
    values: Map.unmodifiable(values),
    failures: Map.unmodifiable(failures),
    cancelled: cancelled,
    startedItems: startedItems,
  );
}
