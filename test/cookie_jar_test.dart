import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/network/cookie_jar.dart';

void main() {
  test('host cookie wins over parent domain cookie with same name', () async {
    final tempDir = await Directory.systemTemp.createTemp('venera_cookie_jar_');
    final jar = CookieJarSql('${tempDir.path}/cookie.db');
    addTearDown(() {
      jar.close();
      tempDir.deleteSync(recursive: true);
    });
    final uri = Uri.parse('https://sub.example.com/path');

    jar.saveFromResponse(uri, [
      Cookie('sid', 'parent')..domain = '.example.com',
      Cookie('sid', 'host')..domain = 'sub.example.com',
    ]);

    expect(jar.loadForRequestCookieHeader(uri), 'sid=host');
  });

  test('malformed persisted cookie rows are skipped per row', () async {
    final tempDir = await Directory.systemTemp.createTemp('venera_cookie_jar_');
    final dbPath = '${tempDir.path}/cookie.db';
    final jar = CookieJarSql(dbPath);
    addTearDown(() {
      jar.close();
      tempDir.deleteSync(recursive: true);
    });
    final uri = Uri.parse('https://sub.example.com/path');

    jar.saveFromResponse(uri, [Cookie('sid', 'valid')]);

    final db = sqlite3.open(dbPath);
    addTearDown(db.close);
    db.execute(
      '''
      INSERT OR REPLACE INTO cookies (
        name,
        value,
        domain,
        path,
        expires,
        secure,
        httpOnly
      ) VALUES (?, ?, ?, ?, ?, ?, ?);
      ''',
      ['bad', 'bad', 'sub.example.com', '/', 'not-an-int', 0, 0],
    );

    expect(jar.loadForRequestCookieHeader(uri), 'sid=valid');
  });
}
