import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/handle_text_share.dart';
import 'package:venera/utils/app_links.dart';

void main() {
  test('parseSafeLinkUri trims valid urls and rejects malformed input', () {
    final uri = parseSafeLinkUri(' https://example.com/a?b=1 ');

    expect(uri?.host, 'example.com');
    expect(uri?.path, '/a');
    expect(parseSafeLinkUri('not a url'), isNull);
    expect(parseSafeLinkUri('https://example.com/%ZZ'), isNull);
  });

  test('global link and share handlers reset without subscriptions', () async {
    await resetAppLinksForTesting();
    await resetTextShareForTesting();

    expect(hasAppLinksSubscriptionForTesting, isFalse);
    expect(hasTextShareSubscriptionForTesting, isFalse);

    await resetAppLinksForTesting();
    await resetTextShareForTesting();
    expect(hasAppLinksSubscriptionForTesting, isFalse);
    expect(hasTextShareSubscriptionForTesting, isFalse);
  });
}
