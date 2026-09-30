import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/sync/koreader/koreader_client.dart';
import 'package:xxread/services/sync/koreader/koreader_config_store.dart';
import 'package:xxread/services/sync/koreader/koreader_epub_locator.dart';
import 'package:xxread/services/sync/koreader/koreader_models.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/koreader/koreader_progress_store.dart';
import 'package:xxread/services/sync/koreader/koreader_sync_service.dart';

/// 记录调用的假客户端，用于验证冲突判定与回声抑制。
class _FakeClient implements KoreaderClient {
  /// getProgress 的返回值；null 表示服务器无记录。
  KoreaderRemoteProgress? remote;

  final List<Map<String, Object?>> puts = <Map<String, Object?>>[];
  int getProgressCalls = 0;
  double? putTimestamp = 1000;

  @override
  KoreaderSyncConfiguration get configuration =>
      const KoreaderSyncConfiguration(serverUrl: 'https://x', username: 'u');

  @override
  Future<bool> authenticate() async => true;

  @override
  Future<void> createAccount(String username, String passwordMd5) async {}

  @override
  Future<KoreaderRemoteProgress?> getProgress(String document) async {
    getProgressCalls++;
    return remote;
  }

  @override
  Future<double?> putProgress({
    required String document,
    required double percentage,
    required String device,
    required String deviceId,
    String? progress,
    Map<String, Object?>? metadata,
  }) async {
    puts.add({
      'document': document,
      'percentage': percentage,
      'progress': progress,
      'device': device,
      'device_id': deviceId,
      'metadata': metadata,
    });
    return putTimestamp;
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Database db;
  late _FakeClient client;
  late KoreaderSyncService service;
  late KoreaderProgressStore store;
  late BookDao bookDao;
  late Directory tempDir;
  late _FakeSecretStorage secrets;
  late _FakePreferences prefs;

  const configuration = KoreaderSyncConfiguration(
    serverUrl: 'https://sync.koreader.rocks',
    username: 'alice',
  );

  const booksSchema = '''
    CREATE TABLE books(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT, author TEXT, filePath TEXT NOT NULL, format TEXT NOT NULL,
      currentPage INTEGER DEFAULT 0, totalPages INTEGER DEFAULT 1,
      reading_progress REAL, importDate INTEGER NOT NULL,
      cached_content TEXT, cached_pages TEXT, file_modified_time INTEGER,
      content_hash TEXT, table_of_contents TEXT, cover_image_path TEXT,
      text_encoding TEXT, last_canonical_locator TEXT,
      last_rendered_locator TEXT, layout_signature TEXT,
      storage_type TEXT NOT NULL DEFAULT 'local',
      source_id TEXT, source_book_id TEXT, source_json TEXT,
      source_book_json TEXT, source_kind TEXT, source_locator TEXT,
      source_modified_time INTEGER
    )
  ''';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('koreader_service_test');
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(booksSchema);
    await db.execute('''
      CREATE TABLE koreader_sync_state(
        book_id INTEGER PRIMARY KEY,
        document_id TEXT NOT NULL,
        checksum_method TEXT NOT NULL DEFAULT 'partial_md5',
        document_size INTEGER, document_modified INTEGER,
        remote_timestamp REAL, synced_percentage REAL,
        last_direction TEXT, updated_at INTEGER NOT NULL
      )
    ''');

    client = _FakeClient();
    store = KoreaderProgressStore(databaseProvider: () async => db);
    bookDao = BookDao(databaseProvider: () async => db);
    secrets = _FakeSecretStorage();
    prefs = _FakePreferences();
    service = KoreaderSyncService();
    service.configureForTest(
      configStore: KoreaderConfigStore(
        secretStorage: secrets,
        preferences: prefs,
      ),
      progressStore: store,
      bookDao: bookDao,
      clientFactory: (_) => client,
    );
    await service.save(configuration: configuration, passwordMd5: 'md5hex');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<int> insertBook({
    required String path,
    double? progress,
    String storageType = 'local',
  }) async {
    return db.insert('books', {
      'title': 'Book',
      'author': 'A',
      'filePath': path,
      'format': 'epub',
      'importDate': 0,
      'reading_progress': progress,
      'storage_type': storageType,
    });
  }

  /// 创建一个 3000 字节的书籍文件，返回其路径。
  Future<String> createBookFile(String name) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(List<int>.generate(3000, (i) => i % 256));
    return file.path;
  }

  Future<int> fileStamp(String path) async =>
      (await File(path).stat()).modified.millisecondsSinceEpoch;

  Future<Book> loadBook(int id) async => (await bookDao.getBookById(id))!;

  group('文档标识', () {
    test('首次拉取时为本地文件计算并缓存 document id', () async {
      final path = await createBookFile('book.epub');
      final id = await insertBook(path: path, progress: 0.2);

      await service.pullIntoBook(await loadBook(id));

      final state = await store.readState(id);
      expect(state, isNotNull);
      expect(state!.documentId, hasLength(32));
      expect(state.checksumMethod, KoreaderChecksumMethod.partialMd5);
      expect(state.documentSize, 3000);
    });

    test('文件未变化时复用缓存的 document id', () async {
      final path = await createBookFile('book.epub');
      final id = await insertBook(path: path, progress: 0.2);
      final book = await loadBook(id);

      await service.pullIntoBook(book);
      final first = (await store.readState(id))!.documentId;
      await service.pullIntoBook(book);

      expect((await store.readState(id))!.documentId, first);
    });

    test('文件内容变化后重算 document id', () async {
      final path = await createBookFile('book.epub');
      final id = await insertBook(path: path, progress: 0.2);
      final book = await loadBook(id);

      await service.pullIntoBook(book);
      final first = (await store.readState(id))!.documentId;

      await File(
        path,
      ).writeAsBytes(List<int>.generate(3000, (i) => (i + 5) % 256));
      await service.pullIntoBook(book);

      expect((await store.readState(id))!.documentId, isNot(first));
    });

    test('切换为文件名校验方式后重算 document id', () async {
      final path = await createBookFile('book.epub');
      final id = await insertBook(path: path, progress: 0.2);
      await service.pullIntoBook(await loadBook(id));
      final contentBased = (await store.readState(id))!.documentId;

      await service.save(
        configuration: configuration.copyWith(
          checksumMethod: KoreaderChecksumMethod.filename,
        ),
        passwordMd5: 'md5hex',
      );
      await service.pullIntoBook(await loadBook(id));

      final state = await store.readState(id);
      expect(state!.documentId, isNot(contentBased));
      expect(state.checksumMethod, KoreaderChecksumMethod.filename);
    });

    test('在线书源书籍不参与同步', () async {
      final id = await insertBook(
        path: 'source://abc',
        progress: 0.5,
        storageType: 'online',
      );

      final result = await service.pullIntoBook(await loadBook(id));

      expect(result.progress, 0.5);
      expect(client.getProgressCalls, 0);
      expect(await store.readState(id), isNull);
    });

    test('文件不存在的书籍不参与同步', () async {
      final id = await insertBook(
        path: '${tempDir.path}/missing.epub',
        progress: 0.5,
      );

      await service.pullIntoBook(await loadBook(id));

      expect(client.getProgressCalls, 0);
    });
  });

  group('拉取', () {
    late int bookId;
    late String filePath;

    setUp(() async {
      filePath = await createBookFile('book.epub');
      bookId = await insertBook(path: filePath, progress: 0.1);
    });

    /// 预置一个「已同步过」的状态，便于测试时间戳比较。
    Future<void> primeSyncedState({
      required double syncedPercentage,
      required double remoteTimestamp,
    }) async {
      await store.upsertDocumentId(
        bookId: bookId,
        documentId: 'cached',
        method: KoreaderChecksumMethod.partialMd5,
        size: 3000,
        modified: await fileStamp(filePath),
      );
      await store.recordSync(
        bookId: bookId,
        direction: 'push',
        syncedPercentage: syncedPercentage,
        remoteTimestamp: remoteTimestamp,
      );
    }

    test('服务器无记录时保持本地进度', () async {
      client.remote = null;

      final result = await service.pullIntoBook(await loadBook(bookId));

      expect(result.progress, 0.1);
      expect(service.takePendingProgression(bookId), isNull);
    });

    test('首次同步采纳远端进度', () async {
      client.remote = const KoreaderRemoteProgress(
        document: 'doc',
        progress: '42',
        percentage: 0.6,
        timestamp: 500,
      );

      final result = await service.pullIntoBook(await loadBook(bookId));

      expect(result.progress, 0.6);
      expect(service.takePendingProgression(bookId), 0.6);
    });

    test('首次同步且开启本地优先时不采纳远端', () async {
      await service.save(
        configuration: configuration.copyWith(preferLocalOnFirstSync: true),
        passwordMd5: 'md5hex',
      );
      client.remote = const KoreaderRemoteProgress(
        document: 'doc',
        progress: '42',
        percentage: 0.6,
        timestamp: 500,
      );

      final result = await service.pullIntoBook(await loadBook(bookId));

      expect(result.progress, 0.1);
      expect(service.takePendingProgression(bookId), isNull);
    });

    test('已同步过且远端时间戳未前进时忽略远端', () async {
      await primeSyncedState(syncedPercentage: 0.1, remoteTimestamp: 900);
      client.remote = const KoreaderRemoteProgress(
        document: 'cached',
        progress: '42',
        percentage: 0.6,
        timestamp: 800,
      );

      final result = await service.pullIntoBook(await loadBook(bookId));

      expect(result.progress, 0.1);
      expect(service.takePendingProgression(bookId), isNull);
    });

    test('已同步过且远端时间戳更新时采纳远端', () async {
      await primeSyncedState(syncedPercentage: 0.1, remoteTimestamp: 500);
      client.remote = const KoreaderRemoteProgress(
        document: 'cached',
        progress: '42',
        percentage: 0.6,
        timestamp: 900,
      );

      final result = await service.pullIntoBook(await loadBook(bookId));

      expect(result.progress, 0.6);
      expect(service.takePendingProgression(bookId), 0.6);
    });

    test('远端百分比与本地实质相同时不改变本地', () async {
      client.remote = const KoreaderRemoteProgress(
        document: 'doc',
        progress: '10',
        percentage: 0.1,
        timestamp: 900,
      );

      final result = await service.pullIntoBook(await loadBook(bookId));

      expect(result.progress, 0.1);
      expect(service.takePendingProgression(bookId), isNull);
    });

    test('远端缺少时间戳时保守起见不覆盖本地', () async {
      await primeSyncedState(syncedPercentage: 0.1, remoteTimestamp: 500);
      client.remote = const KoreaderRemoteProgress(
        document: 'cached',
        progress: '42',
        percentage: 0.6,
      );

      final result = await service.pullIntoBook(await loadBook(bookId));

      expect(result.progress, 0.1);
    });

    test('syncOnOpen 关闭时完全不请求服务器', () async {
      await service.save(
        configuration: configuration.copyWith(syncOnOpen: false),
        passwordMd5: 'md5hex',
      );

      await service.pullIntoBook(await loadBook(bookId));

      expect(client.getProgressCalls, 0);
    });

    test('未配置同步时原样返回', () async {
      await service.clear();

      final result = await service.pullIntoBook(await loadBook(bookId));

      expect(result.progress, 0.1);
      expect(client.getProgressCalls, 0);
    });

    test('拉取后记录同步状态以便后续判断新旧', () async {
      client.remote = const KoreaderRemoteProgress(
        document: 'doc',
        progress: '42',
        percentage: 0.6,
        timestamp: 777,
      );

      await service.pullIntoBook(await loadBook(bookId));

      final state = await store.readState(bookId);
      expect(state!.syncedPercentage, 0.6);
      expect(state.remoteTimestamp, 777);
      expect(state.lastDirection, 'pull');
    });

    test('拉取的进度被持久化到书籍记录', () async {
      client.remote = const KoreaderRemoteProgress(
        document: 'doc',
        progress: '42',
        percentage: 0.6,
        timestamp: 777,
      );

      await service.pullIntoBook(await loadBook(bookId));

      final persisted = await loadBook(bookId);
      expect(persisted.readingProgress, 0.6);
    });
  });

  group('推送', () {
    late int bookId;
    late String filePath;

    setUp(() async {
      filePath = await createBookFile('book.epub');
      bookId = await insertBook(path: filePath, progress: 0.3);
    });

    Future<void> primeSyncedState({
      required double syncedPercentage,
      required double remoteTimestamp,
    }) async {
      await store.upsertDocumentId(
        bookId: bookId,
        documentId: 'cached',
        method: KoreaderChecksumMethod.partialMd5,
        size: 3000,
        modified: await fileStamp(filePath),
      );
      await store.recordSync(
        bookId: bookId,
        direction: 'push',
        syncedPercentage: syncedPercentage,
        remoteTimestamp: remoteTimestamp,
      );
    }

    test('推送进度并记录同步状态', () async {
      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      expect(client.puts, hasLength(1));
      expect(client.puts.single['percentage'], 0.3);
      final state = await store.readState(bookId);
      expect(state!.syncedPercentage, 0.3);
      expect(state.lastDirection, 'push');
      expect(state.remoteTimestamp, 1000);
    });

    test('回声抑制：与服务端一致的百分比不再推送', () async {
      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();
      expect(client.puts, hasLength(1));

      // 再次记录同一数值（例如刚拉取后阅读器又保存了一次）。
      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      expect(client.puts, hasLength(1));
    });

    test('回声抑制：与上次推送仅差阈值以内的百分比不推送', () async {
      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      service.noteLocalProgress(bookId, 0.3005);
      await service.flushPending();

      expect(client.puts, hasLength(1));
    });

    test('超过阈值的进度变化会推送', () async {
      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      service.noteLocalProgress(bookId, 0.5);
      await service.flushPending();

      expect(client.puts, hasLength(2));
      expect(client.puts.last['percentage'], 0.5);
    });

    test('推送前对账：远端更新时采纳远端而不是覆盖', () async {
      await primeSyncedState(syncedPercentage: 0.2, remoteTimestamp: 500);
      // 别的设备在此期间写入了更新的进度。
      client.remote = const KoreaderRemoteProgress(
        document: 'cached',
        progress: '80',
        percentage: 0.8,
        timestamp: 900,
      );

      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      expect(client.puts, isEmpty, reason: '不应覆盖其他设备更新的进度');
      expect((await loadBook(bookId)).progress, 0.8);
      expect(service.takePendingProgression(bookId), 0.8);
      expect((await store.readState(bookId))!.remoteTimestamp, 900);
    });

    test('推送前对账：远端时间戳未前进时正常推送', () async {
      await primeSyncedState(syncedPercentage: 0.2, remoteTimestamp: 900);
      client.remote = const KoreaderRemoteProgress(
        document: 'cached',
        progress: '20',
        percentage: 0.2,
        timestamp: 800,
      );

      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      expect(client.puts, hasLength(1));
      expect(client.puts.single['percentage'], 0.3);
    });

    test('syncOnSave 关闭时不排队推送', () async {
      await service.save(
        configuration: configuration.copyWith(syncOnSave: false),
        passwordMd5: 'md5hex',
      );

      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      expect(client.puts, isEmpty);
    });

    test('推送携带设备名与设备标识', () async {
      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      final put = client.puts.single;
      expect(put['device'], isNotEmpty);
      expect(put['device_id'], isNotEmpty);
    });

    test('推送使用书籍的 document id', () async {
      client.remote = null;
      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      final state = await store.readState(bookId);
      expect(client.puts.single['document'], state!.documentId);
    });

    test('推送携带元数据便于自定义服务端展示', () async {
      service.noteLocalProgress(bookId, 0.3);
      await service.flushPending();

      final metadata = client.puts.single['metadata'] as Map<String, Object?>;
      expect(metadata['filename'], 'book.epub');
      expect(metadata['title'], 'Book');
    });

    test('无待推送内容时 flush 不产生请求', () async {
      await service.flushPending();
      expect(client.puts, isEmpty);
    });

    test('在线书籍不会被推送', () async {
      final id = await insertBook(
        path: 'source://x',
        progress: 0.9,
        storageType: 'online',
      );

      service.noteLocalProgress(id, 0.9);
      await service.flushPending();

      expect(client.puts, isEmpty);
    });
  });

  group('批量同步（立即同步）', () {
    test('推送本地有进度的书籍', () async {
      final path = await createBookFile('a.epub');
      await insertBook(path: path, progress: 0.4);
      final other = await createBookFile('b.epub');
      await insertBook(path: other, progress: 0.7);
      client.remote = null;

      final result = await service.pushDirtyBooks();

      expect(result.pushed, 2);
      expect(result.failed, 0);
      expect(client.puts, hasLength(2));
    });

    test('跳过已同步的书籍', () async {
      final path = await createBookFile('a.epub');
      final id = await insertBook(path: path, progress: 0.4);

      service.noteLocalProgress(id, 0.4);
      await service.flushPending();
      expect(client.puts, hasLength(1));

      final result = await service.pushDirtyBooks();

      expect(result.skipped, 1);
      expect(result.pushed, 0);
    });

    test('无阅读进度的书籍不参与批量同步', () async {
      final path = await createBookFile('a.epub');
      await insertBook(path: path);

      final result = await service.pushDirtyBooks();

      expect(result.total, 0);
      expect(client.puts, isEmpty);
    });

    test('在线书籍不参与批量同步', () async {
      await insertBook(
        path: 'source://x',
        progress: 0.5,
        storageType: 'online',
      );

      final result = await service.pushDirtyBooks();

      expect(result.total, 0);
    });

    test('未配置时抛出明确错误', () async {
      await service.clear();

      expect(
        () => service.pushDirtyBooks(),
        throwsA(
          isA<KoreaderSyncFailure>().having(
            (failure) => failure.code,
            'code',
            KoreaderSyncErrorCode.notConfigured,
          ),
        ),
      );
    });
  });

  group('测试连接', () {
    test('通过时返回成功', () async {
      final result = await service.testConnection(
        configuration: configuration,
        passwordMd5: 'md5hex',
      );
      expect(result.success, isTrue);
    });

    test('拒绝明文 http 公网地址', () async {
      final result = await service.testConnection(
        configuration: const KoreaderSyncConfiguration(
          serverUrl: 'http://sync.example.com',
          username: 'alice',
        ),
        passwordMd5: 'md5hex',
      );
      expect(result.success, isFalse);
      expect(result.errorCode, KoreaderSyncErrorCode.insecureConnection);
    });

    test('凭据错误时返回认证失败', () async {
      final rejecting = _RejectingClient();
      final scoped = KoreaderSyncService()
        ..configureForTest(
          progressStore: store,
          bookDao: bookDao,
          clientFactory: (_) => rejecting,
        );

      final result = await scoped.testConnection(
        configuration: configuration,
        passwordMd5: 'md5hex',
      );

      expect(result.success, isFalse);
      expect(result.errorCode, KoreaderSyncErrorCode.authentication);
    });
  });

  // 用真实 sample-alice.epub 验证 XPointer 精确落点的推送/拉取链路已接通：
  // 推送把「章节归档路径 + 章内偏移」编码为 crengine XPointer 发给服务器；
  // 拉取把远端 XPointer 解回可精确复原的 KoreaderPendingApply。
  group('XPointer 精确落点链路', () {
    const epubFixture = 'test/fixtures/koreader/sample-alice.epub';
    const oracleFixture = 'test/fixtures/koreader/sample-alice.json';

    /// 从真值里取一个能解析的落点，作为推送/拉取的输入。
    ({String xpointer, String archivePath, int offsetUtf16}) sampleAnchor() {
      final locator = KoreaderEpubLocator.open(epubFixture)!;
      final oracle =
          jsonDecode(File(oracleFixture).readAsStringSync())
              as Map<String, dynamic>;
      final fragments = (oracle['fragments'] as List)
          .cast<Map<String, dynamic>>();
      for (final frag in fragments) {
        final words = (frag['words'] as List).cast<Map<String, dynamic>>();
        if (words.isEmpty) continue;
        final xp = words.first['xp'] as String;
        final resolved = locator.resolveXPointer(xp);
        if (resolved == null) continue;
        return (
          xpointer: xp,
          archivePath: resolved.archivePath,
          offsetUtf16: resolved.offsetUtf16,
        );
      }
      fail('真值里找不到可解析的 XPointer');
    }

    test('推送 EPUB 落点时 progress 字段发送 crengine XPointer', () async {
      final id = await insertBook(path: epubFixture, progress: 0.1);
      client.remote = null;
      final anchor = sampleAnchor();

      service.noteLocalProgress(
        id,
        0.5,
        chapterArchivePath: anchor.archivePath,
        offsetUtf16: anchor.offsetUtf16,
      );
      await service.flushPending();

      expect(client.puts, hasLength(1));
      final progress = client.puts.single['progress'] as String?;
      expect(progress, isNotNull);
      expect(KoreaderEpubLocator.looksLikeXPointer(progress!), isTrue);

      // 推送的 XPointer 必须能解回同一个章内偏移（生成侧闭环）。
      final roundTrip = KoreaderEpubLocator.open(
        epubFixture,
      )!.resolveXPointer(progress);
      expect(roundTrip, isNotNull);
      expect(roundTrip!.archivePath, anchor.archivePath);
      expect(roundTrip.offsetUtf16, anchor.offsetUtf16);
    });

    test('缺少章内落点时 progress 退化为百分比字符串', () async {
      final id = await insertBook(path: epubFixture, progress: 0.1);
      client.remote = null;

      service.noteLocalProgress(id, 0.5);
      await service.flushPending();

      expect(client.puts, hasLength(1));
      final progress = client.puts.single['progress'] as String?;
      // 无落点时不应发 XPointer；由客户端回退为百分比（此处替身记录到的是 null，
      // 表示服务未生成 XPointer，KoreaderClient 会以 percentage 兜底）。
      expect(progress, isNull);
    });

    test('拉取远端 XPointer 时产出可精确复原的待应用落点', () async {
      final id = await insertBook(path: epubFixture, progress: 0.1);
      final anchor = sampleAnchor();
      client.remote = KoreaderRemoteProgress(
        document: 'doc',
        progress: anchor.xpointer,
        percentage: 0.6,
        timestamp: 500,
      );

      await service.pullIntoBook(await loadBook(id));

      final pending = service.takePendingApply(id);
      expect(pending, isNotNull);
      expect(pending!.hasPrecisePosition, isTrue);
      expect(pending.chapterArchivePath, anchor.archivePath);
      expect(pending.offsetUtf16, anchor.offsetUtf16);
      expect(pending.percentage, 0.6);
    });

    test('远端为纯百分比字符串时退化为按百分比应用', () async {
      final id = await insertBook(path: epubFixture, progress: 0.1);
      client.remote = const KoreaderRemoteProgress(
        document: 'doc',
        progress: '0.600000',
        percentage: 0.6,
        timestamp: 500,
      );

      await service.pullIntoBook(await loadBook(id));

      final pending = service.takePendingApply(id);
      expect(pending, isNotNull);
      expect(pending!.hasPrecisePosition, isFalse);
      expect(pending.percentage, 0.6);
    });
  });
}

class _RejectingClient extends _FakeClient {
  @override
  Future<bool> authenticate() async => false;
}

class _FakeSecretStorage implements SyncSecretStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakePreferences implements SyncPreferences {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
