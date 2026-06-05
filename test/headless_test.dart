import 'package:flutter_test/flutter_test.dart';
import 'package:venera/headless.dart';

void main() {
  test('decodeHeadlessJsonPayload tolerates malformed json', () {
    expect(decodeHeadlessJsonPayload('[{"id":"1"}]'), isA<List<dynamic>>());
    expect(decodeHeadlessJsonPayload('{bad'), isNull);
  });

  test('buildHeadlessUpdatedComicsOutput reports malformed json', () {
    expect(
      buildHeadlessUpdatedComicsOutput(status: 'success', json: '{bad'),
      {
        'status': 'error',
        'message': 'Updated comics list is malformed.',
        'data': <Object>[],
      },
    );

    expect(
      buildHeadlessUpdatedComicsOutput(
        status: 'success',
        json: '[{"id":"1"}]',
      ),
      {
        'status': 'success',
        'message': 'Updated comics list.',
        'data': [
          {'id': '1'},
        ],
      },
    );
  });
}
