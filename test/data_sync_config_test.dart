import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  test('normalizeWebDavConfig accepts empty and complete configs', () {
    expect(normalizeWebDavConfig([]), isEmpty);
    expect(normalizeWebDavConfig(['https://example.test', 'user', 'pass']), [
      'https://example.test',
      'user',
      'pass',
    ]);
  });

  test('normalizeWebDavConfig rejects malformed config values', () {
    expect(normalizeWebDavConfig(null), isNull);
    expect(normalizeWebDavConfig('https://example.test'), isNull);
    expect(normalizeWebDavConfig(['url', 'user']), isNull);
    expect(normalizeWebDavConfig(['url', 'user', 'pass', 'extra']), isNull);
    expect(normalizeWebDavConfig(['url', 'user', 1]), isNull);
    expect(normalizeWebDavConfig([1, 'url', 'user', 'pass']), isNull);
  });

  test('normalizeWebDavAutoSync accepts only bool values', () {
    expect(normalizeWebDavAutoSync(true), isTrue);
    expect(normalizeWebDavAutoSync(false), isFalse);
    expect(normalizeWebDavAutoSync('true'), isFalse);
    expect(normalizeWebDavAutoSync(1, fallback: true), isTrue);
  });

  test(
    'cacheFileNameForRemoteDataFile sanitizes remote names for cache use',
    () {
      expect(
        cacheFileNameForRemoteDataFile('sync-12.venera'),
        'sync-12.venera',
      );
      expect(
        cacheFileNameForRemoteDataFile('../sync-12.venera'),
        '.. sync-12.venera',
      );
      expect(cacheFileNameForRemoteDataFile('sync-12.zip'), isNull);
      expect(cacheFileNameForRemoteDataFile(null), isNull);
    },
  );

  test('isUsableRemoteDataFileName rejects path-like remote names', () {
    expect(isUsableRemoteDataFileName('sync-12.venera'), isTrue);
    expect(isUsableRemoteDataFileName('../sync-12.venera'), isFalse);
    expect(isUsableRemoteDataFileName(r'..\sync-12.venera'), isFalse);
    expect(isUsableRemoteDataFileName('sync-12.zip'), isFalse);
  });

  test('remoteDataFileInfoForName parses day and version numerically', () {
    final info = remoteDataFileInfoForName('20260605-10.venera');

    expect(info?.remoteName, '20260605-10.venera');
    expect(info?.cacheName, '20260605-10.venera');
    expect(info?.prefix, '20260605');
    expect(info?.numericPrefix, 20260605);
    expect(info?.version, 10);
    final legacyInfo = remoteDataFileInfoForName('sync-12.venera');
    expect(legacyInfo?.prefix, 'sync');
    expect(legacyInfo?.numericPrefix, isNull);
    expect(legacyInfo?.version, 12);
    expect(remoteDataFileInfoForName('20260605-old.venera'), isNull);
  });

  test('latestRemoteDataFileName uses numeric version ordering', () {
    expect(
      latestRemoteDataFileName([
        '20260605-9.venera',
        '20260605-10.venera',
        '20260604-99.venera',
      ]),
      '20260604-99.venera',
    );
    expect(
      latestRemoteDataFileName(['20260605-9.venera', '20260605-10.venera']),
      '20260605-10.venera',
    );
  });

  test(
    'remoteDataFilesToRemoveBeforeUpload does not remove same file twice',
    () {
      final removals = remoteDataFilesToRemoveBeforeUpload([
        '20260604-3.venera',
        '20260603-2.venera',
        '20260602-1.venera',
      ], '20260604-');

      expect(removals, ['20260604-3.venera']);
    },
  );

  test('remoteDataFilesToRemoveBeforeUpload removes all same-day backups', () {
    final removals = remoteDataFilesToRemoveBeforeUpload([
      '20260604-9.venera',
      '20260604-10.venera',
      '20260603-11.venera',
    ], '20260604-');

    expect(removals, ['20260604-9.venera', '20260604-10.venera']);
  });

  test(
    'remoteDataFilesToRemoveBeforeUpload prunes to leave room for new file',
    () {
      final removals = remoteDataFilesToRemoveBeforeUpload([
        for (var i = 1; i <= 10; i++)
          '202606${i.toString().padLeft(2, '0')}-$i.venera',
      ], '20260611-');

      expect(removals, ['20260601-1.venera']);
    },
  );

  test('remoteDataFilesToRemoveBeforeUpload prunes by numeric order', () {
    final removals = remoteDataFilesToRemoveBeforeUpload(
      ['20260605-9.venera', '20260605-10.venera', '20260604-99.venera'],
      '20260606-',
      maxFiles: 2,
    );

    expect(removals, ['20260604-99.venera', '20260605-9.venera']);
  });

  test('remoteDataFilesToRemoveBeforeUpload ignores unusable remote names', () {
    final removals = remoteDataFilesToRemoveBeforeUpload([
      '../20260601-1.venera',
      '20260601-1.zip',
      '20260601-1.venera',
    ], '20260602-');

    expect(removals, isEmpty);
  });

  test(
    'remote backup upload never removes old files before upload succeeds',
    () async {
      final events = <String>[];

      await expectLater(
        uploadRemoteBackupSafely(
          upload: () async {
            events.add('upload');
            throw StateError('upload failed');
          },
          filesToRemove: const ['old.venera'],
          remove: (name) async => events.add('remove:$name'),
        ),
        throwsStateError,
      );

      expect(events, ['upload']);
    },
  );

  test(
    'remote cleanup failures do not invalidate a successful upload',
    () async {
      final events = <String>[];
      final cleanupErrors = <String>[];

      await uploadRemoteBackupSafely(
        upload: () async => events.add('upload'),
        filesToRemove: const ['old-1.venera', 'old-2.venera'],
        remove: (name) async {
          events.add('remove:$name');
          if (name == 'old-1.venera') throw StateError('remove failed');
        },
        onRemoveError: (name, _, _) => cleanupErrors.add(name),
      );

      expect(events, ['upload', 'remove:old-1.venera', 'remove:old-2.venera']);
      expect(cleanupErrors, ['old-1.venera']);
    },
  );
}
