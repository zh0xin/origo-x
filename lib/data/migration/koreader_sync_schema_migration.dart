// 文件说明：KOReader（kosync）进度同步 Schema 迁移——新增 koreader_sync_state 侧表。
// 技术要点：CREATE TABLE IF NOT EXISTS、幂等迁移、forward-only 策略、外键级联删除。

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// KOReader 进度同步 Schema 迁移。
///
/// 新增 `koreader_sync_state` 侧表，按书籍记录 kosync 同步信箱状态：
/// - `document_id`：KOReader 用于标识书籍的校验值（partial MD5 或文件名 MD5）
/// - 缓存元信息（`document_size` / `document_modified` / `checksum_method`），
///   文件或校验方式变化时据此判断是否需要重算
/// - `remote_timestamp` / `synced_percentage` / `last_direction`：冲突判定依据
///
/// 设计原则：
/// - 幂等：CREATE TABLE IF NOT EXISTS，重复执行安全
/// - 安全：纯新增表，不改动 books 表结构，不影响既有查询与模型
/// - forward-only：不提供 downgrade 执行路径
/// - 与 DatabaseService._onUpgrade 对齐，应在版本升级回调中调用
///
/// 之所以用独立侧表而非给 books 加列：BookDao 使用显式列清单查询，
/// Book.fromMap/toMap 为穷举实现，给 books 加列需要连带改动模型和每一处
/// 显式查询，改动面与回归风险都大得多。
class KoreaderSyncSchemaMigration {
  KoreaderSyncSchemaMigration._();

  /// 当前迁移版本号，用于标识本批次迁移。
  /// DatabaseService._dbVersion 应在此批次完成后递增到包含此版本号。
  static const int migrationVersion = 22;

  static const String tableName = 'koreader_sync_state';

  /// 执行迁移。幂等：使用 CREATE TABLE IF NOT EXISTS。
  ///
  /// 调用方式：
  /// ```dart
  /// // 在 DatabaseService._onUpgrade 中：
  /// if (oldVersion < 22) {
  ///   await KoreaderSyncSchemaMigration.migrate(db);
  /// }
  /// ```
  static Future<void> migrate(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName(
        book_id INTEGER PRIMARY KEY,
        document_id TEXT NOT NULL,
        checksum_method TEXT NOT NULL DEFAULT 'partial_md5',
        document_size INTEGER,
        document_modified INTEGER,
        remote_timestamp REAL,
        synced_percentage REAL,
        last_direction TEXT,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
      )
    ''');

    // 按 document_id 反查书籍：拉取远端进度时若本地尚未记录该书，
    // 需要凭文档标识定位到对应的书籍行。
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_koreader_sync_state_document '
      'ON $tableName (document_id)',
    );
  }

  // ---- Downgrade 说明（不执行） ----
  //
  // 本迁移为 forward-only，不提供 downgrade 路径。
  // 原因：
  // 1. 新表只保存同步信箱状态，丢弃后仅需重新与服务器对账，不影响本地阅读数据
  // 2. 旧版本代码不会查询该表，保留它无副作用
  // 3. 降级后重新升级时，CREATE TABLE IF NOT EXISTS 会复用既有表
}
