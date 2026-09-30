// 文件说明：KOReader 进度同步编排——拉取、推送、去抖、冲突判定与回声抑制。
// 技术要点：单例；kosync 为服务端时间戳后写胜出（last-write-wins）；
// 推送前先对账（reconcile）以免覆盖其他设备更新的进度。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../models/book.dart';
import '../../books/book_dao.dart';
import 'koreader_client.dart';
import 'koreader_config_store.dart';
import 'koreader_epub_locator.dart';
import 'koreader_models.dart';
import 'koreader_partial_md5.dart';
import 'koreader_progress_store.dart';

/// 判定两个百分比是否「实质相同」的阈值。
const double koreaderProgressEpsilon = 0.001;

/// 进度保存到实际推送之间的去抖窗口，避免翻页逐次打网络。
const Duration koreaderPushDebounce = Duration(seconds: 15);

/// 单次拉取的超时。阅读器打开时不能因为同步卡住启动。
const Duration koreaderPullTimeout = Duration(seconds: 4);

class KoreaderSyncService {
  KoreaderSyncService._internal();

  static final KoreaderSyncService instance = KoreaderSyncService._internal();

  /// 供测试注入替身。
  @visibleForTesting
  static set debugInstance(KoreaderSyncService? value) => _override = value;

  static KoreaderSyncService? _override;

  factory KoreaderSyncService() => _override ?? instance;

  KoreaderConfigStore? _configStore;
  KoreaderProgressStore? _progressStore;
  BookDao? _bookDao;
  KoreaderClientFactory? _clientFactory;

  KoreaderSyncConfiguration? _configuration;
  String? _passwordMd5;
  String? _deviceId;

  /// 待推送的本地进度，键为书籍 id。
  final Map<int, double> _pendingPush = <int, double>{};
  final Map<int, Timer> _pushTimers = <int, Timer>{};

  /// 待推送的章内精确落点（EPUB），键为书籍 id。用于生成 XPointer。
  final Map<int, _PushPosition> _pendingPushPosition = <int, _PushPosition>{};

  /// 已从远端拉取、等待原生阅读器在章节加载完成后应用的进度。
  final Map<int, KoreaderPendingApply> _pendingApply =
      <int, KoreaderPendingApply>{};

  Future<void>? _flushing;

  KoreaderConfigStore get _config => _configStore ??= KoreaderConfigStore();

  KoreaderProgressStore get _store =>
      _progressStore ??= KoreaderProgressStore();

  BookDao get _books => _bookDao ??= BookDao();

  KoreaderClient _createClient(
    KoreaderSyncConfiguration configuration,
    String passwordMd5,
  ) {
    final factory = _clientFactory;
    if (factory != null) return factory(configuration);
    return KoreaderClient(
      configuration: configuration,
      passwordMd5: passwordMd5,
    );
  }

  @visibleForTesting
  void configureForTest({
    KoreaderConfigStore? configStore,
    KoreaderProgressStore? progressStore,
    BookDao? bookDao,
    KoreaderClientFactory? clientFactory,
  }) {
    _configStore = configStore;
    _progressStore = progressStore;
    _bookDao = bookDao;
    _clientFactory = clientFactory;
  }

  bool get isConfigured => _configuration != null;

  KoreaderSyncConfiguration? get configuration => _configuration;

  /// 凭据的 MD5。仅用于重新保存配置时回填，不对外展示。
  String? get passwordMd5 => _passwordMd5;

  String? get deviceId => _deviceId;

  /// 读取本地配置。失败不抛出——同步不可用不应阻断阅读。
  Future<void> initialize() async {
    try {
      final credentials = await _config.readCredentials();
      if (credentials != null) {
        _configuration = credentials.configuration;
        _passwordMd5 = credentials.passwordMd5;
      }
      _deviceId = await _config.readDeviceId();
      _deviceId ??= _generateDeviceId();
      await _config.saveDeviceId(_deviceId!);
    } catch (error) {
      debugPrint('⚠️ KOReader 同步初始化失败: $error');
    }
  }

  /// 保存配置并立即验证凭据。
  Future<void> save({
    required KoreaderSyncConfiguration configuration,
    required String passwordMd5,
  }) async {
    await _config.save(configuration, passwordMd5);
    _configuration = configuration;
    _passwordMd5 = passwordMd5;
  }

  Future<void> clear() async {
    for (final timer in _pushTimers.values) {
      timer.cancel();
    }
    _pushTimers.clear();
    _pendingPush.clear();
    _pendingPushPosition.clear();
    _pendingApply.clear();
    await _config.clear();
    _configuration = null;
    _passwordMd5 = null;
  }

  Future<KoreaderConnectionTestResult> testConnection({
    required KoreaderSyncConfiguration configuration,
    required String passwordMd5,
  }) async {
    final client = _createClient(configuration, passwordMd5);
    try {
      validateKoreaderConfiguration(configuration, passwordMd5: passwordMd5);
      final ok = await client.authenticate();
      return KoreaderConnectionTestResult(
        success: ok,
        errorCode: ok ? null : KoreaderSyncErrorCode.authentication,
      );
    } on KoreaderSyncFailure catch (failure) {
      return KoreaderConnectionTestResult(
        success: false,
        errorCode: failure.code,
      );
    } catch (_) {
      return const KoreaderConnectionTestResult(
        success: false,
        errorCode: KoreaderSyncErrorCode.network,
      );
    } finally {
      client.close();
    }
  }

  Future<void> registerAccount({
    required String serverUrl,
    required String username,
    required String password,
    required bool allowInsecurePrivateHttp,
  }) async {
    final configuration = KoreaderSyncConfiguration(
      serverUrl: serverUrl,
      username: username,
      allowInsecurePrivateHttp: allowInsecurePrivateHttp,
    );
    final passwordMd5 = koreaderPasswordHash(password);
    validateKoreaderConfiguration(configuration, passwordMd5: passwordMd5);
    final client = _createClient(configuration, passwordMd5);
    try {
      await client.createAccount(username, passwordMd5);
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------- 拉取

  /// 打开书籍前尝试拉取远端进度。
  ///
  /// 返回可能已被远端进度更新的 [book]。任何失败都原样返回入参，
  /// 保证本地阅读不受同步故障影响。
  Future<Book> pullIntoBook(Book book, {Duration? timeout}) async {
    final configuration = _configuration;
    final bookId = book.id;
    if (configuration == null || bookId == null) return book;
    if (!configuration.syncOnOpen) return book;
    if (book.isOnline) return book;

    try {
      final outcome = await _pull(
        book,
        configuration,
      ).timeout(timeout ?? koreaderPullTimeout);
      if (outcome == null) return book;
      // 数值一致时也要记录服务器时间戳，但无需改动本地记录。
      if (!outcome.changed) {
        await _store.recordSync(
          bookId: bookId,
          direction: 'pull',
          syncedPercentage: outcome.percentage,
          remoteTimestamp: outcome.timestamp,
        );
        return book;
      }
      // 必须落库：否则应用重启后阅读器会回到同步前的旧位置。
      await _books.updateBookProgress(
        bookId,
        book.currentPage,
        readingProgress: outcome.percentage,
      );
      _pendingApply[bookId] = _buildPendingApply(book, outcome);
      await _store.recordSync(
        bookId: bookId,
        direction: 'pull',
        syncedPercentage: outcome.percentage,
        remoteTimestamp: outcome.timestamp,
      );
      return book.copyWith(readingProgress: outcome.percentage);
    } catch (error) {
      debugPrint('⚠️ KOReader 拉取进度失败: $error');
      return book;
    }
  }

  /// 执行一次拉取判定，返回应采纳的远端进度；无需采纳时返回 null。
  Future<_PullOutcome?> _pull(
    Book book,
    KoreaderSyncConfiguration configuration,
  ) async {
    final passwordMd5 = _passwordMd5;
    final bookId = book.id;
    if (passwordMd5 == null || bookId == null) return null;

    final documentId = await _documentIdFor(book, configuration);
    if (documentId == null) return null;

    final client = _createClient(configuration, passwordMd5);
    try {
      final remote = await client.getProgress(documentId);
      if (remote == null) return null;

      final state = await _store.readState(bookId);
      final local = book.progress;
      if ((remote.percentage - local).abs() <= koreaderProgressEpsilon) {
        // 数值一致：仅记录时间戳，便于后续判断远端是否又前进。
        return _PullOutcome(
          remote.percentage,
          remote.timestamp,
          progress: remote.progress,
          changed: false,
        );
      }

      final knownTimestamp = state?.remoteTimestamp;
      if (knownTimestamp == null) {
        // 首次同步。默认采纳远端（KOReader 侧已有进度），
        // 除非用户显式选择本地优先。
        if (configuration.preferLocalOnFirstSync) return null;
        return _PullOutcome(
          remote.percentage,
          remote.timestamp,
          progress: remote.progress,
        );
      }

      final remoteTimestamp = remote.timestamp;
      if (remoteTimestamp == null) {
        // 服务端不返回时间戳时无法判断新旧，保守起见不覆盖本地。
        return null;
      }
      if (remoteTimestamp > knownTimestamp) {
        return _PullOutcome(
          remote.percentage,
          remoteTimestamp,
          progress: remote.progress,
        );
      }
      return null;
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------- 推送

  /// 记录本地进度变化，去抖后推送。
  ///
  /// [chapterArchivePath] / [offsetUtf16] 为 EPUB 章内精确落点（可空）：提供时
  /// 推送会据此生成 crengine XPointer，实现与 KOReader 的精确位置互通；缺省时
  /// 退化为百分比同步。
  void noteLocalProgress(
    int bookId,
    double? percentage, {
    String? chapterArchivePath,
    int? offsetUtf16,
  }) {
    final configuration = _configuration;
    if (configuration == null || !configuration.syncOnSave) return;
    if (percentage == null) return;
    _pendingPush[bookId] = percentage.clamp(0.0, 1.0);
    if (chapterArchivePath != null && offsetUtf16 != null) {
      _pendingPushPosition[bookId] = _PushPosition(
        archivePath: chapterArchivePath,
        offsetUtf16: offsetUtf16,
      );
    } else {
      _pendingPushPosition.remove(bookId);
    }
    _pushTimers[bookId]?.cancel();
    _pushTimers[bookId] = Timer(koreaderPushDebounce, () {
      _pushTimers.remove(bookId);
      unawaited(flushPending());
    });
  }

  /// 立即发送所有待推送进度。阅读器关闭、应用挂起时调用。
  Future<void> flushPending() {
    final running = _flushing;
    if (running != null) return running;
    final future = _flush();
    _flushing = future;
    return future.whenComplete(() => _flushing = null);
  }

  Future<void> _flush() async {
    final configuration = _configuration;
    final passwordMd5 = _passwordMd5;
    if (configuration == null || passwordMd5 == null) return;
    if (_pendingPush.isEmpty) return;

    final queued = Map<int, double>.from(_pendingPush);
    _pendingPush.clear();

    for (final entry in queued.entries) {
      final position = _pendingPushPosition.remove(entry.key);
      try {
        await _pushOne(
          bookId: entry.key,
          percentage: entry.value,
          configuration: configuration,
          passwordMd5: passwordMd5,
          position: position,
        );
      } catch (error) {
        debugPrint('⚠️ KOReader 推送进度失败(book=${entry.key}): $error');
      }
    }
  }

  /// 推送单本书进度。推送前先与服务器对账，避免覆盖其他设备更新过的进度。
  Future<void> _pushOne({
    required int bookId,
    required double percentage,
    required KoreaderSyncConfiguration configuration,
    required String passwordMd5,
    _PushPosition? position,
  }) async {
    final book = await _books.getBookById(bookId);
    if (book == null || book.isOnline) return;

    final documentId = await _documentIdFor(book, configuration);
    if (documentId == null) return;

    final state = await _store.readState(bookId);

    // 回声抑制：与服务端已达成一致的数值无需再推。
    final synced = state?.syncedPercentage;
    if (synced != null &&
        (percentage - synced).abs() <= koreaderProgressEpsilon) {
      return;
    }

    final client = _createClient(configuration, passwordMd5);
    try {
      // 推送前对账：若远端在此期间被别的设备推进，采纳远端而不是覆盖它。
      final remote = await client.getProgress(documentId);
      final knownTimestamp = state?.remoteTimestamp;
      if (remote != null &&
          remote.timestamp != null &&
          knownTimestamp != null &&
          remote.timestamp! > knownTimestamp &&
          (remote.percentage - percentage).abs() > koreaderProgressEpsilon) {
        await _books.updateBookProgress(
          bookId,
          book.currentPage,
          readingProgress: remote.percentage,
        );
        _pendingApply[bookId] = _buildPendingApply(
          book,
          _PullOutcome(
            remote.percentage,
            remote.timestamp,
            progress: remote.progress,
          ),
        );
        await _store.recordSync(
          bookId: bookId,
          direction: 'pull',
          syncedPercentage: remote.percentage,
          remoteTimestamp: remote.timestamp,
        );
        return;
      }

      // EPUB 优先推送 crengine XPointer，实现与 KOReader 的精确落点互通。
      final xpointer = _buildXPointer(book, position);
      final timestamp = await client.putProgress(
        document: documentId,
        percentage: percentage,
        progress: xpointer,
        device: _deviceLabel(configuration),
        deviceId: _deviceId ?? 'xxread',
        metadata: {'filename': p.basename(book.filePath), 'title': book.title},
      );
      await _store.recordSync(
        bookId: bookId,
        direction: 'push',
        syncedPercentage: percentage,
        remoteTimestamp: timestamp,
      );
    } finally {
      client.close();
    }
  }

  /// 批量推送本地有进度的书籍，用于「立即同步」。
  Future<KoreaderSyncRunResult> pushDirtyBooks({int limit = 100}) async {
    final configuration = _configuration;
    final passwordMd5 = _passwordMd5;
    if (configuration == null || passwordMd5 == null) {
      throw const KoreaderSyncFailure(
        KoreaderSyncErrorCode.notConfigured,
        'KOReader sync is not configured.',
      );
    }
    final candidates = await _store.localBooksWithProgress(limit: limit);
    var pushed = 0;
    var pulled = 0;
    var skipped = 0;
    var failed = 0;
    for (final candidate in candidates) {
      try {
        final state = await _store.readState(candidate.bookId);
        final synced = state?.syncedPercentage;
        if (synced != null &&
            (candidate.percentage - synced).abs() <= koreaderProgressEpsilon) {
          skipped++;
          continue;
        }
        final before = state?.syncedPercentage;
        await _pushOne(
          bookId: candidate.bookId,
          percentage: candidate.percentage,
          configuration: configuration,
          passwordMd5: passwordMd5,
        );
        final after = await _store.readState(candidate.bookId);
        if (after?.lastDirection == 'pull' &&
            before != after?.syncedPercentage) {
          pulled++;
        } else {
          pushed++;
        }
      } catch (error) {
        debugPrint('⚠️ KOReader 批量同步失败(book=${candidate.bookId}): $error');
        failed++;
      }
    }
    await _config.saveLastSyncAt(DateTime.now());
    return KoreaderSyncRunResult(
      pushed: pushed,
      pulled: pulled,
      skipped: skipped,
      failed: failed,
    );
  }

  /// 取走待应用的进度（一次性），返回百分比。返回 null 表示无需覆盖本地。
  ///
  /// 仅返回百分比，供不关心精确落点的调用方（如测试、PDF/漫画）使用。
  /// 原生文本阅读器请改用 [takePendingApply] 以获得 EPUB 精确落点。
  double? takePendingProgression(int bookId) =>
      _pendingApply.remove(bookId)?.percentage;

  /// 取走待应用的进度（一次性），含 EPUB 精确落点（若有）。
  KoreaderPendingApply? takePendingApply(int bookId) =>
      _pendingApply.remove(bookId);

  @visibleForTesting
  void debugSetPendingProgression(int bookId, double percentage) =>
      _pendingApply[bookId] = KoreaderPendingApply(percentage: percentage);

  // ---------------------------------------------------------------- 内部

  /// 依据远端 progress 字段为可精确定位的 EPUB 构建待应用落点。
  KoreaderPendingApply _buildPendingApply(Book book, _PullOutcome outcome) {
    final progress = outcome.progress;
    if (progress == null ||
        book.isOnline ||
        book.filePath.isEmpty ||
        !KoreaderEpubLocator.looksLikeXPointer(progress)) {
      return KoreaderPendingApply(percentage: outcome.percentage);
    }
    try {
      final locator = KoreaderEpubLocator.open(book.filePath);
      final resolved = locator?.resolveXPointer(progress);
      if (resolved == null) {
        return KoreaderPendingApply(percentage: outcome.percentage);
      }
      return KoreaderPendingApply(
        percentage: outcome.percentage,
        chapterArchivePath: resolved.archivePath,
        offsetUtf16: resolved.offsetUtf16,
      );
    } catch (error) {
      debugPrint('⚠️ KOReader XPointer 解析失败: $error');
      return KoreaderPendingApply(percentage: outcome.percentage);
    }
  }

  /// 为待推送的 EPUB 落点生成 XPointer；非 EPUB 或无落点时返回 null（退化为百分比）。
  String? _buildXPointer(Book book, _PushPosition? position) {
    if (position == null || book.isOnline || book.filePath.isEmpty) return null;
    try {
      final locator = KoreaderEpubLocator.open(book.filePath);
      return locator?.buildXPointer(
        archivePath: position.archivePath,
        offsetUtf16: position.offsetUtf16,
      );
    } catch (error) {
      debugPrint('⚠️ KOReader XPointer 生成失败: $error');
      return null;
    }
  }

  /// 计算书籍的 kosync 文档标识，命中缓存则直接复用。
  Future<String?> _documentIdFor(
    Book book,
    KoreaderSyncConfiguration configuration,
  ) async {
    final bookId = book.id;
    if (bookId == null) return null;
    if (!await koreaderDocumentIdAvailable(book.filePath)) return null;

    final file = File(book.filePath);
    final stat = await file.stat();
    final size = stat.size;
    final modified = stat.modified.millisecondsSinceEpoch;

    final cached = await _store.readState(bookId);
    if (cached != null &&
        cached.matchesFile(
          method: configuration.checksumMethod,
          size: size,
          modified: modified,
        )) {
      return cached.documentId;
    }

    final documentId = await koreaderDocumentId(
      filePath: book.filePath,
      method: configuration.checksumMethod,
    );
    await _store.upsertDocumentId(
      bookId: bookId,
      documentId: documentId,
      method: configuration.checksumMethod,
      size: size,
      modified: modified,
    );
    return documentId;
  }

  String _deviceLabel(KoreaderSyncConfiguration configuration) {
    final configured = configuration.deviceName;
    if (configured != null && configured.trim().isNotEmpty) {
      return configured.trim();
    }
    if (Platform.isAndroid) return 'Open Reading (Android)';
    if (Platform.isIOS) return 'Open Reading (iOS)';
    if (Platform.isWindows) return 'Open Reading (Windows)';
    if (Platform.isMacOS) return 'Open Reading (macOS)';
    if (Platform.isLinux) return 'Open Reading (Linux)';
    return 'Open Reading';
  }

  static String _generateDeviceId() {
    final random = math.Random.secure();
    const alphabet = '0123456789ABCDEF';
    final buffer = StringBuffer('XXR');
    for (var i = 0; i < 13; i++) {
      buffer.write(alphabet[random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }
}

class _PullOutcome {
  const _PullOutcome(
    this.percentage,
    this.timestamp, {
    this.progress,
    this.changed = true,
  });

  final double percentage;
  final double? timestamp;

  /// 远端原始 progress 字段（EPUB 为 crengine XPointer）。
  final String? progress;
  final bool changed;
}

/// 待推送的 EPUB 章内精确落点。
class _PushPosition {
  const _PushPosition({required this.archivePath, required this.offsetUtf16});

  final String archivePath;
  final int offsetUtf16;
}

/// 待被阅读器应用的远端进度。[chapterArchivePath] 与 [offsetUtf16] 同时非空时
/// 表示可精确复原的 EPUB 落点，否则仅有百分比（降级为按章节均分近似）。
class KoreaderPendingApply {
  const KoreaderPendingApply({
    required this.percentage,
    this.chapterArchivePath,
    this.offsetUtf16,
  });

  final double percentage;
  final String? chapterArchivePath;
  final int? offsetUtf16;

  bool get hasPrecisePosition =>
      chapterArchivePath != null && offsetUtf16 != null;
}
