import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';

void main() {
  test('source data JS messages are ignored when the source is gone', () {
    expect(shouldHandleSourceDataMessage(null), isFalse);
  });

  test('JS message string fields reject malformed values', () {
    expect(normalizeJsMessageString('source'), 'source');
    expect(normalizeJsMessageString(''), isNull);
    expect(normalizeJsMessageString(null), isNull);
    expect(normalizeJsMessageString(1), isNull);
    expect(normalizeJsMessageString(['source']), isNull);
  });

  test('JS log level falls back to warning for malformed values', () {
    expect(normalizeJsLogLevel('error'), LogLevel.error);
    expect(normalizeJsLogLevel('warning'), LogLevel.warning);
    expect(normalizeJsLogLevel('info'), LogLevel.info);
    expect(normalizeJsLogLevel(null), LogLevel.warning);
    expect(normalizeJsLogLevel(1), LogLevel.warning);
    expect(normalizeJsLogLevel('bad'), LogLevel.warning);
  });

  test('JS delay and clipboard values tolerate malformed inputs', () {
    expect(normalizeJsDelayMilliseconds(20), 20);
    expect(normalizeJsDelayMilliseconds(20.9), 20);
    expect(normalizeJsDelayMilliseconds('30'), 30);
    expect(normalizeJsDelayMilliseconds(-1), 0);
    expect(normalizeJsDelayMilliseconds('bad'), 0);
    expect(normalizeJsDelayMilliseconds(null), 0);

    expect(normalizeJsClipboardText('text'), 'text');
    expect(normalizeJsClipboardText(123), '123');
    expect(normalizeJsClipboardText(null), '');
  });

  test('JS random request tolerates malformed bounds', () {
    expect(normalizeJsRandomRequest(min: 1, max: 5, type: 'double'), (
      min: 1,
      max: 5,
      type: 'double',
    ));
    expect(normalizeJsRandomRequest(min: '2.5', max: '6', type: 'int'), (
      min: 2.5,
      max: 6,
      type: 'int',
    ));
    expect(normalizeJsRandomRequest(min: 'bad', max: null, type: null), (
      min: 0,
      max: 1,
      type: 'int',
    ));
    expect(normalizeJsRandomRequest(min: 10, max: 2, type: 'double'), (
      min: 2,
      max: 10,
      type: 'double',
    ));
  });

  test('JS convert request rejects malformed control fields', () {
    expect(normalizeJsConvertType('utf8'), 'utf8');
    expect(normalizeJsConvertType(''), '');
    expect(normalizeJsConvertType(null), isNull);
    expect(normalizeJsConvertType(1), isNull);
    expect(normalizeJsConvertType(['utf8']), isNull);

    expect(normalizeJsConvertIsEncode(true), isTrue);
    expect(normalizeJsConvertIsEncode(false), isFalse);
    expect(normalizeJsConvertIsEncode(null), isNull);
    expect(normalizeJsConvertIsEncode(1), isNull);
    expect(normalizeJsConvertIsEncode('true'), isNull);
  });

  test('source login JS state returns false for missing sources', () {
    expect(resolveSourceLoginStateForJs(null), isFalse);

    final source = ComicSource(
      'Source',
      'source',
      null,
      null,
      null,
      null,
      const [],
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      'source.js',
      'https://example.test/source.js',
      '1.0.0',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );

    expect(resolveSourceLoginStateForJs(source), isFalse);

    source.data['account'] = 'ok';
    expect(resolveSourceLoginStateForJs(source), isTrue);

    source.markLoginExpired();
    expect(resolveSourceLoginStateForJs(source), isFalse);
  });

  test('HTML callbacks ignore missing document handles', () {
    final engine = JsEngine();

    engine.handleHtmlCallback({
      'function': 'parse',
      'key': 9001,
      'data': '<main><a id="first">first</a></main>',
    });
    engine.handleHtmlCallback({'function': 'dispose', 'key': 9001});

    expect(
      engine.handleHtmlCallback({
        'function': 'querySelector',
        'key': 9001,
        'query': 'a',
      }),
      isNull,
    );
    expect(
      engine.handleHtmlCallback({
        'function': 'querySelectorAll',
        'key': 9001,
        'query': 'a',
      }),
      isEmpty,
    );
    expect(
      engine.handleHtmlCallback({'function': 'getText', 'doc': 9001, 'key': 0}),
      isNull,
    );
  });

  test('HTML callbacks ignore stale element and node handles', () {
    final engine = JsEngine();

    engine.handleHtmlCallback({
      'function': 'parse',
      'key': 9002,
      'data': '<main><a id="first" class="link">first</a></main>',
    });

    expect(
      engine.handleHtmlCallback({
        'function': 'getText',
        'doc': 9002,
        'key': 99,
      }),
      isNull,
    );
    expect(
      engine.handleHtmlCallback({
        'function': 'getAttributes',
        'doc': 9002,
        'key': 99,
      }),
      isEmpty,
    );
    expect(
      engine.handleHtmlCallback({
        'function': 'dom_querySelectorAll',
        'doc': 9002,
        'key': 99,
        'query': 'a',
      }),
      isEmpty,
    );
    expect(
      engine.handleHtmlCallback({
        'function': 'node_type',
        'doc': 9002,
        'key': 99,
      }),
      'unknown',
    );
    expect(
      engine.handleHtmlCallback({
        'function': 'node_to_element',
        'doc': 9002,
        'key': 99,
      }),
      isNull,
    );
  });
}
