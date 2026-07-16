import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqlite3/common.dart' show Row;
import 'package:venera/core/database/app_database.dart';

final class SourceDocument {
  SourceDocument._({
    required this.name,
    required Uint8List? content,
    required this.sha256,
    required this.expectedLength,
    required this.available,
  }) : content = content == null
           ? null
           : Uint8List.fromList(content).asUnmodifiableView() {
    _validateName(name);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid source document SHA-256');
    }
    if (expectedLength < 0) {
      throw const FormatException('Invalid source document length');
    }
    if (available != (content != null)) {
      throw const FormatException('Source availability does not match content');
    }
    if (content != null &&
        (content.length != expectedLength || digestBytes(content) != sha256)) {
      throw const FormatException('Source document content is corrupt');
    }
  }

  factory SourceDocument.available({
    required String name,
    required List<int> content,
  }) {
    final bytes = Uint8List.fromList(content);
    return SourceDocument._(
      name: name,
      content: bytes,
      sha256: digestBytes(bytes),
      expectedLength: bytes.length,
      available: true,
    );
  }

  factory SourceDocument.missing({
    required String name,
    required String sha256,
    required int expectedLength,
  }) {
    return SourceDocument._(
      name: name,
      content: null,
      sha256: sha256,
      expectedLength: expectedLength,
      available: false,
    );
  }

  factory SourceDocument.fromRow(Row row) {
    final content = row['content'];
    if (content != null && content is! Uint8List) {
      throw const FormatException('Invalid source document content');
    }
    return SourceDocument._(
      name: row['name'] as String,
      content: content as Uint8List?,
      sha256: row['sha256'] as String,
      expectedLength: row['expected_length'] as int,
      available: row['available'] == 1,
    );
  }

  final String name;
  final Uint8List? content;
  final String sha256;
  final int expectedLength;
  final bool available;

  static String digestBytes(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();

  static void _validateName(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\')) {
      throw ArgumentError.value(name, 'name', 'must be a plain file name');
    }
  }
}

abstract interface class SourceRepository {
  Future<SourceDocument?> get(String name);

  Future<List<SourceDocument>> list({bool? available});

  Stream<List<SourceDocument>> watch({bool? available});

  Future<void> upsert(SourceDocument document);

  Future<void> replaceAll(Iterable<SourceDocument> documents);

  Future<void> remove(String name);
}

final class SqliteSourceRepository implements SourceRepository {
  SqliteSourceRepository(this._database);

  final AppDatabase _database;

  @override
  Future<SourceDocument?> get(String name) async {
    final row = await _database.raw.getOptional(
      'SELECT * FROM source_documents WHERE name = ?',
      [name],
    );
    return row == null ? null : SourceDocument.fromRow(row);
  }

  @override
  Future<List<SourceDocument>> list({bool? available}) async {
    final rows = await _database.raw.getAll('''
      SELECT * FROM source_documents
      ${available == null ? '' : 'WHERE available = ?'}
      ORDER BY name COLLATE NOCASE
      ''', available == null ? const [] : [available ? 1 : 0]);
    return rows.map(SourceDocument.fromRow).toList(growable: false);
  }

  @override
  Stream<List<SourceDocument>> watch({bool? available}) {
    return _database.raw
        .watch(
          '''
          SELECT * FROM source_documents
          ${available == null ? '' : 'WHERE available = ?'}
          ORDER BY name COLLATE NOCASE
          ''',
          parameters: available == null ? const [] : [available ? 1 : 0],
          triggerOnTables: const {'source_documents'},
        )
        .map(
          (rows) => rows.map(SourceDocument.fromRow).toList(growable: false),
        );
  }

  @override
  Future<void> upsert(SourceDocument document) async {
    await _database.raw.execute(_upsertSql, _parameters(document));
  }

  @override
  Future<void> replaceAll(Iterable<SourceDocument> documents) async {
    final values = documents.toList(growable: false);
    final names = <String>{};
    for (final document in values) {
      if (!names.add(document.name)) {
        throw ArgumentError.value(
          document.name,
          'documents',
          'contains a duplicate name',
        );
      }
    }
    await _database.raw.writeTransaction((tx) async {
      await tx.execute('DELETE FROM source_documents');
      if (values.isNotEmpty) {
        await tx.executeBatch(
          _upsertSql,
          values.map(_parameters).toList(growable: false),
        );
      }
    });
  }

  @override
  Future<void> remove(String name) async {
    await _database.raw.execute('DELETE FROM source_documents WHERE name = ?', [
      name,
    ]);
  }

  static const _upsertSql = '''
    INSERT INTO source_documents(
      name, content, sha256, expected_length, available
    ) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(name) DO UPDATE SET
      content = excluded.content,
      sha256 = excluded.sha256,
      expected_length = excluded.expected_length,
      available = excluded.available
  ''';

  static List<Object?> _parameters(SourceDocument document) => [
    document.name,
    document.content,
    document.sha256,
    document.expectedLength,
    document.available ? 1 : 0,
  ];
}
