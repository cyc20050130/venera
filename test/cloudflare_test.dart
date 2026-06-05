import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/cloudflare.dart';

void main() {
  test('parseCloudflareChallengeUri accepts only absolute http urls', () {
    expect(
      parseCloudflareChallengeUri('https://example.com/challenge')?.host,
      'example.com',
    );
    expect(
      parseCloudflareChallengeUri('http://example.com/challenge')?.scheme,
      'http',
    );

    expect(parseCloudflareChallengeUri('/challenge'), isNull);
    expect(parseCloudflareChallengeUri('file:///tmp/challenge'), isNull);
    expect(parseCloudflareChallengeUri('https://example.com/%ZZ'), isNull);
  });

  test('buildCloudflareCookies uses an eTLD-style domain fallback', () {
    final cookies = buildCloudflareCookies(
      Uri.parse('https://sub.example.com/challenge'),
      {'cf_clearance': 'token'},
    );

    expect(cookies, hasLength(1));
    expect(cookies.single.name, 'cf_clearance');
    expect(cookies.single.value, 'token');
    expect(cookies.single.domain, '.example.com');
  });

  test('saveCloudflareCookies skips unavailable jar without throwing', () {
    expect(
      saveCloudflareCookies(
        null,
        Uri.parse('https://example.com/challenge'),
        {'cf_clearance': 'token'},
      ),
      isFalse,
    );
  });
}
