import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/koreader_sync_schema_migration.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<Database> openDatabase() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('CREATE TABLE books(id INTEGER PRIMARY KEY)');
    return db;
  }

  test('迁移创建 koreader_sync_state 表及所需列', () async {
    final db = await openDatabase();

    await KoreaderSyncSchemaMigration.migrate(db);

    final columns = await db.rawQuery(
      'PRAGMA table_info(${KoreaderSyncSchemaMigration.tableName})',
    );
    expect(
      columns.map((row) => row['name']),
      containsAll(<String>[
        'book_id',
        'document_id',
        'checksum_method',
        'document_size',
        'document_modified',
        'remote_timestamp',
        'synced_percentage',
        'last_direction',
        'updated_at',
      ]),
    );
  });

  test('迁移是幂等的，可重复执行', () async {
    final db = await openDatabase();

    await KoreaderSyncSchemaMigration.migrate(db);
    await KoreaderSyncSchemaMigration.migrate(db);
    await KoreaderSyncSchemaMigration.migrate(db);

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [KoreaderSyncSchemaMigration.tableName],
    );
    expect(tables, hasLength(1));
  });

  test('创建 document_id 索引以便反查书籍', () async {
    final db = await openDatabase();

    await KoreaderSyncSchemaMigration.migrate(db);

    final indexes = await db.rawQuery(
      'PRAGMA index_list(${KoreaderSyncSchemaMigration.tableName})',
    );
    expect(
      indexes.map((row) => row['name']),
      contains('idx_koreader_sync_state_document'),
    );
  });

  test('book_id 为主键，重复插入同一书籍失败', () async {
    final db = await openDatabase();
    await KoreaderSyncSchemaMigration.migrate(db);
    await db.insert('books', {'id': 1});

    await db.insert('koreader_sync_state', {
      'book_id': 1,
      'document_id': 'abc',
      'updated_at': 0,
    });

    expect(
      () => db.insert('koreader_sync_state', {
        'book_id': 1,
        'document_id': 'def',
        'updated_at': 0,
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('删除书籍时级联清除同步状态', () async {
    final db = await openDatabase();
    // SQLite 默认不启用外键约束，需显式打开才能验证级联行为。
    await db.execute('PRAGMA foreign_keys = ON');
    await KoreaderSyncSchemaMigration.migrate(db);
    await db.insert('books', {'id': 1});
    await db.insert('koreader_sync_state', {
      'book_id': 1,
      'document_id': 'abc',
      'updated_at': 0,
    });

    await db.delete('books', where: 'id = ?', whereArgs: [1]);

    expect(await db.query('koreader_sync_state'), isEmpty);
  });

  test('checksum_method 默认 partial_md5', () async {
    final db = await openDatabase();
    await KoreaderSyncSchemaMigration.migrate(db);
    await db.insert('books', {'id': 1});
    await db.insert('koreader_sync_state', {
      'book_id': 1,
      'document_id': 'abc',
      'updated_at': 0,
    });

    final rows = await db.query('koreader_sync_state');
    expect(rows.single['checksum_method'], 'partial_md5');
  });
}
