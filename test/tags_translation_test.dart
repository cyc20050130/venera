import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/tags_translation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('namespace translation normalizes simple plural tag names', () async {
    appdata.settings['language'] = 'zh-CN';
    await TagsTranslation.readData();

    expect(
      TagsTranslation.translationTagWithNamespace('teachers', 'female'),
      '教师',
    );
  });

  test('readData can be called repeatedly', () async {
    appdata.settings['language'] = 'zh-CN';
    await TagsTranslation.readData();
    await TagsTranslation.readData();

    expect(
      TagsTranslation.translationTagWithNamespace('teachers', 'female'),
      '教师',
    );
  });
}
