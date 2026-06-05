import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/opencc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await OpenCC.init();
  });

  test('detects and converts simplified and traditional Chinese generally', () {
    expect(OpenCC.hasChineseSimplified('汉'), isTrue);
    expect(OpenCC.hasChineseSimplified('plain ascii'), isFalse);

    expect(OpenCC.hasChineseTraditional('漢'), isTrue);
    expect(OpenCC.hasChineseTraditional('plain ascii'), isFalse);

    expect(OpenCC.simplifiedToTraditional('汉'), '漢');
    expect(OpenCC.traditionalToSimplified('漢'), '汉');
  });

  test('init is idempotent', () async {
    await OpenCC.init();

    expect(OpenCC.simplifiedToTraditional('汉'), '漢');
  });
}
