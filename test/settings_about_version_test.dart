import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/settings/settings_page.dart';

void main() {
  test('isNewerAppVersion compares numeric segments safely', () {
    expect(isNewerAppVersion('1.7.0', '1.6.25'), isTrue);
    expect(isNewerAppVersion('1.6.25.1', '1.6.25'), isTrue);
    expect(isNewerAppVersion('1.6', '1.6.25'), isFalse);
    expect(isNewerAppVersion('1.6.25', '1.6.25'), isFalse);
    expect(isNewerAppVersion('1.6.bad', '1.6.25'), isFalse);
    expect(isNewerAppVersion('bad', '1.6.25'), isFalse);
  });
}
