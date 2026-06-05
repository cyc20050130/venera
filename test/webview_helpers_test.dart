import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/webview.dart';

void main() {
  test('normalizeWebviewUserAgent strips balanced quotes only', () {
    expect(normalizeWebviewUserAgent('"UA"'), 'UA');
    expect(normalizeWebviewUserAgent("'UA'"), 'UA');
    expect(normalizeWebviewUserAgent('"'), '"');
    expect(normalizeWebviewUserAgent(1), isNull);
  });

  test('parseDesktopWebviewDocumentMessage validates message shape', () {
    expect(parseDesktopWebviewDocumentMessage(''), isNull);
    expect(parseDesktopWebviewDocumentMessage('{bad'), isNull);
    expect(
      parseDesktopWebviewDocumentMessage('{"id":"other","data":{}}'),
      isNull,
    );
    expect(
      parseDesktopWebviewDocumentMessage(
        '{"id":"document_created","data":null}',
      ),
      isNull,
    );
    expect(
      parseDesktopWebviewDocumentMessage(
        '{"id":"document_created","data":{"title":1}}',
      ),
      isNull,
    );

    expect(
      parseDesktopWebviewDocumentMessage(
        '{"id":"document_created","data":{"title":"Title","ua":"\\"UA\\""}}',
      ),
      {'title': 'Title', 'ua': 'UA'},
    );
  });

  test('desktop webview close handling ignores stale close callbacks', () {
    expect(
      shouldHandleDesktopWebviewClose(
        callbackSession: 2,
        currentSession: 2,
        isCurrentWebview: true,
        closingSession: null,
        hasActiveWebview: true,
      ),
      isTrue,
    );

    expect(
      shouldHandleDesktopWebviewClose(
        callbackSession: 2,
        currentSession: 2,
        isCurrentWebview: false,
        closingSession: 2,
        hasActiveWebview: false,
      ),
      isTrue,
    );

    expect(
      shouldHandleDesktopWebviewClose(
        callbackSession: 1,
        currentSession: 2,
        isCurrentWebview: false,
        closingSession: 1,
        hasActiveWebview: true,
      ),
      isFalse,
    );

    expect(
      shouldHandleDesktopWebviewClose(
        callbackSession: 1,
        currentSession: 2,
        isCurrentWebview: false,
        closingSession: 1,
        hasActiveWebview: false,
      ),
      isFalse,
    );
  });
}
