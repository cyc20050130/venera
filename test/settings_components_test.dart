import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/settings/settings_page.dart';

void main() {
  test('normalizeSettingsPageIndex preserves unset and clamps bad input', () {
    expect(normalizeSettingsPageIndex(-1, 8), -1);
    expect(normalizeSettingsPageIndex(0, 8), 0);
    expect(normalizeSettingsPageIndex('7', 8), 7);
    expect(normalizeSettingsPageIndex(8, 8), -1);
    expect(normalizeSettingsPageIndex(99, 8), -1);
    expect(normalizeSettingsPageIndex('bad', 8), -1);
    expect(normalizeSettingsPageIndex(-1, 8, allowUnset: false), 0);
    expect(normalizeSettingsPageIndex(99, 8, allowUnset: false), 0);
    expect(normalizeSettingsPageIndex(3, 0), -1);
    expect(normalizeSettingsPageIndex(3, 0, allowUnset: false), 0);
  });

  test('normalizeSettingSwitchValue tolerates malformed synced values', () {
    expect(normalizeSettingSwitchValue(true), isTrue);
    expect(normalizeSettingSwitchValue('true'), isTrue);
    expect(normalizeSettingSwitchValue('false', fallback: true), isFalse);
    expect(normalizeSettingSwitchValue('bad'), isFalse);
  });

  test('normalizeCustomImageProcessingScript tolerates malformed values', () {
    expect(
      normalizeCustomImageProcessingScript('function processImage() {}'),
      ('function processImage() {}'),
    );
    expect(normalizeCustomImageProcessingScript(''), '');
    expect(
      normalizeCustomImageProcessingScript(1),
      defaultCustomImageProcessing,
    );
    expect(
      normalizeCustomImageProcessingScript(['function processImage() {}']),
      defaultCustomImageProcessing,
    );
    expect(
      normalizeCustomImageProcessingScript(null),
      defaultCustomImageProcessing,
    );
  });

  test(
    'normalizeSettingSliderValue clamps malformed and out-of-range values',
    () {
      expect(
        normalizeSettingSliderValue('2', fallback: 1, min: 0.5, max: 3),
        2,
      );
      expect(
        normalizeSettingSliderValue('bad', fallback: 1, min: 0.5, max: 3),
        1,
      );
      expect(
        normalizeSettingSliderValue(-1, fallback: 1, min: 0.5, max: 3),
        0.5,
      );
      expect(normalizeSettingSliderValue(9, fallback: 1, min: 0.5, max: 3), 3);
    },
  );

  test(
    'shouldApplyMultiPageFilterSelection requires mounted non-empty input',
    () {
      expect(
        shouldApplyMultiPageFilterSelection(mounted: true, selected: ['home']),
        isTrue,
      );
      expect(
        shouldApplyMultiPageFilterSelection(mounted: false, selected: ['home']),
        isFalse,
      );
      expect(
        shouldApplyMultiPageFilterSelection(mounted: true, selected: const []),
        isFalse,
      );
    },
  );
}
