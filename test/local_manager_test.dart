import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';

void main() {
  late Directory tempDir;
  late LocalManager manager;

  File snapshotFile() => File('${tempDir.path}/downloading_tasks.json');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-local-test-');
    App.dataPath = tempDir.path;
    manager = LocalManager();
    manager.downloadingTasks.clear();
    if (await snapshotFile().exists()) {
      await snapshotFile().delete();
    }
  });

  tearDown(() async {
    manager.downloadingTasks.clear();
    await manager.flushCurrentDownloadingTasks();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('scheduled task snapshots keep only the latest queued state', () async {
    manager.downloadingTasks.add(_FakeDownloadTask('first'));
    final firstSave = manager.scheduleSaveCurrentDownloadingTasks(
      delay: const Duration(milliseconds: 120),
    );

    await Future.delayed(const Duration(milliseconds: 20));
    manager.downloadingTasks
      ..clear()
      ..add(_FakeDownloadTask('second'));
    final secondSave = manager.scheduleSaveCurrentDownloadingTasks(
      delay: const Duration(milliseconds: 120),
    );

    await Future.wait([firstSave, secondSave]);

    final json =
        jsonDecode(await snapshotFile().readAsString()) as List<dynamic>;
    expect(json, hasLength(1));
    expect((json.first as Map<String, dynamic>)['id'], 'second');
  });

  test('flushCurrentDownloadingTasks writes immediately', () async {
    manager.downloadingTasks.add(_FakeDownloadTask('flush-now'));

    manager.scheduleSaveCurrentDownloadingTasks(
      delay: const Duration(seconds: 30),
    );
    await manager.flushCurrentDownloadingTasks();

    expect(await snapshotFile().exists(), isTrue);
    final json =
        jsonDecode(await snapshotFile().readAsString()) as List<dynamic>;
    expect(json, hasLength(1));
    expect((json.first as Map<String, dynamic>)['id'], 'flush-now');
  });
}

class _FakeDownloadTask extends DownloadTask {
  _FakeDownloadTask(this.fakeId);

  final String fakeId;

  @override
  String? get cover => null;

  @override
  String get id => fakeId;

  @override
  bool get isError => false;

  @override
  bool get isPaused => true;

  @override
  String get message => fakeId;

  @override
  double get progress => 0;

  @override
  int get speed => 0;

  @override
  String get title => fakeId;

  @override
  ComicType get comicType => ComicType.local;

  @override
  void cancel() {}

  @override
  LocalComic toLocalComic() {
    throw UnimplementedError();
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'FakeDownloadTask', 'id': fakeId, 'message': fakeId};
  }

  @override
  void pause() {}

  @override
  void resume() {}
}
