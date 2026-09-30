// 文件说明：koreader_sync_state 侧表的读写，以及同步候选书籍查询。
// 技术要点：SQLite DAO，独立侧表避免改动 books 表结构与 Book 模型。

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../data/migration/koreader_sync_schema_migration.dart';
import '../../../services/core/database_service.dart';
import 'koreader_models.dart';

/// 一本书的 kosync 信箱状态。
class KoreaderSyncState {
  const KoreaderSyncState({
    required this.bookId,
    required this.documentId,
    required this.checksumMethod,
    this.documentSize,
    this.documentModified,
    this.remoteTimestamp,
    this.syncedPercentage,
    this.lastDirection,
  });

  final int bookId;
  final String documentId;
  final KoreaderChecksumMethod checksumMethod;

  /// 计算 [documentId] 时书籍文件的大小与修改时间，用于判断缓存是否失效。
  final int? documentSize;
  final int? documentModified;

  /// 最近一次已知的服务器时间戳。为空表示本地从未成功同步过。
  final double? remoteTimestamp;

  /// 最近一次同步达成一致的百分比。用于回声抑制：
  /// 本地进度与之相同则无需再推送。
  final double? syncedPercentage;

  /// 'push' 或 'pull'，仅用于诊断展示。
  final String? lastDirection;

  /// 文档标识缓存是否仍然可用。
  bool matchesFile({
    required KoreaderChecksumMethod method,
    required int? size,
    required int? modified,
  }) =>
      checksumMethod == method &&
      documentSize == size &&
      documentModified == modified;

  static KoreaderSyncState fromRow(Map<String, Object?> row) =>
      KoreaderSyncState(
        bookId: row['book_id'] as int,
        documentId: row['document_id'] as String,
        checksumMethod: KoreaderChecksumMethod.fromStorage(
          row['checksum_method'] as String?,
        ),
        documentSize: row['document_size'] as int?,
        documentModified: row['document_modified'] as int?,
        remoteTimestamp: (row['remote_timestamp'] as num?)?.toDouble(),
        syncedPercentage: (row['synced_percentage'] as num?)?.toDouble(),
        lastDirection: row['last_direction'] as String?,
      );
}

/// 同步候选书籍（本地文件、有阅读进度）。
class KoreaderLocalBook {
  const KoreaderLocalBook({
    required this.bookId,
    required this.title,
    required this.filePath,
    required this.percentage,
  });

  final int bookId;
  final String title;
  final String filePath;
  final double percentage;
}

class KoreaderProgressStore {
  /// [databaseProvider] 仅供测试注入独立数据库；
  /// 生产环境走 [DatabaseService] 单例。
  KoreaderProgressStore({Future<Database> Function()? databaseProvider})
    : _databaseProvider =
          databaseProvider ?? (() => DatabaseService().database);

  final Future<Database> Function() _databaseProvider;

  Future<Database> get _db => _databaseProvider();

  static const String _table = KoreaderSyncSchemaMigration.tableName;

  Future<KoreaderSyncState?> readState(int bookId) async {
    final db = await _db;
    final rows = await db.query(
      _table,
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return KoreaderSyncState.fromRow(rows.first);
  }

  /// 写入或更新文档标识缓存，保留既有的同步信箱字段。
  Future<void> upsertDocumentId({
    required int bookId,
    required String documentId,
    required KoreaderChecksumMethod method,
    required int? size,
    required int? modified,
  }) async {
    final db = await _db;
    await db.rawInsert(
      '''
      INSERT INTO $_table (
        book_id, document_id, checksum_method,
        document_size, document_modified, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(book_id) DO UPDATE SET
        document_id = excluded.document_id,
        checksum_method = excluded.checksum_method,
        document_size = excluded.document_size,
        document_modified = excluded.document_modified,
        updated_at = excluded.updated_at
      ''',
      [
        bookId,
        documentId,
        method.storageValue,
        size,
        modified,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 记录一次同步结果。
  ///
  /// [syncedPercentage] 为本次与服务端达成一致的百分比；
  /// [remoteTimestamp] 为服务端时间戳。二者传 null 表示保持原值不变。
  Future<void> recordSync({
    required int bookId,
    required String direction,
    double? syncedPercentage,
    double? remoteTimestamp,
  }) async {
    final db = await _db;
    final values = <String, Object?>{
      'last_direction': direction,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (syncedPercentage != null) {
      values['synced_percentage'] = syncedPercentage;
    }
    if (remoteTimestamp != null) {
      values['remote_timestamp'] = remoteTimestamp;
    }
    await db.update(_table, values, where: 'book_id = ?', whereArgs: [bookId]);
  }

  Future<void> deleteState(int bookId) async {
    final db = await _db;
    await db.delete(_table, where: 'book_id = ?', whereArgs: [bookId]);
  }

  /// 列出可参与同步的本地书籍（非在线书源、已落盘、有阅读进度）。
  ///
  /// 用于「立即同步」时批量推送：只推送本地读过的书，
  /// 在线书源书籍没有文件无法计算内容标识，直接排除。
  Future<List<KoreaderLocalBook>> localBooksWithProgress({
    int limit = 100,
  }) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''
      SELECT id, title, filePath, reading_progress
      FROM books
      WHERE storage_type != 'online'
        AND reading_progress IS NOT NULL
        AND filePath IS NOT NULL
        AND filePath != ''
      ORDER BY reading_progress DESC
      LIMIT ?
      ''',
      [limit],
    );
    return rows
        .map(
          (row) => KoreaderLocalBook(
            bookId: row['id'] as int,
            title: row['title'] as String? ?? '',
            filePath: row['filePath'] as String? ?? '',
            percentage: ((row['reading_progress'] as num?)?.toDouble() ?? 0)
                .clamp(0.0, 1.0),
          ),
        )
        .toList(growable: false);
  }
}
