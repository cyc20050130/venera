import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/downloading_page.dart';

void main() {
  test('download task listener rebind uses object identity', () {
    final first = _EqualTask('same');
    final sameBusinessTask = _EqualTask('same');

    expect(shouldRebindDownloadTaskListener(null, null), isFalse);
    expect(shouldRebindDownloadTaskListener(null, first), isTrue);
    expect(shouldRebindDownloadTaskListener(first, first), isFalse);
    expect(first == sameBusinessTask, isTrue);
    expect(
      shouldRebindDownloadTaskListener(first, sameBusinessTask),
      isTrue,
    );
  });
}

class _EqualTask {
  const _EqualTask(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is _EqualTask && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
