// 文件说明：KOReader（kosync）进度同步的配置、状态、错误与远端进度模型。
// 技术要点：纯数据模型，不依赖 Flutter，便于单元测试。

/// KOReader 标识书籍所用的校验方式。
///
/// kosync 协议支持两种互斥的文档标识策略，第三方客户端需要两种都支持才能
/// 与用户已在 KOReader 中建立的进度对上：
/// - [partialMd5]：对文件内容抽样计算 MD5（KOReader 默认，随内容走，改名不影响）
/// - [filename]：对文件名 basename 计算 MD5（快，但同名文件会碰撞）
enum KoreaderChecksumMethod {
  partialMd5('partial_md5'),
  filename('filename');

  const KoreaderChecksumMethod(this.storageValue);

  final String storageValue;

  static KoreaderChecksumMethod fromStorage(String? value) {
    for (final method in values) {
      if (method.storageValue == value) return method;
    }
    return partialMd5;
  }
}

enum KoreaderSyncStatus {
  unconfigured,
  idle,
  testing,
  syncing,
  success,
  partialFailure,
  failed,
}

enum KoreaderSyncErrorCode {
  invalidConfiguration,
  insecureConnection,
  authentication,
  usernameTaken,
  network,
  timeout,
  server,
  malformedResponse,
  secureStorage,
  localFileRequired,
  notConfigured,
  unknown,
}

class KoreaderSyncFailure implements Exception {
  const KoreaderSyncFailure(this.code, this.message, {this.statusCode});

  final KoreaderSyncErrorCode code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'KoreaderSyncFailure($code, $message)';
}

/// 配置表单草稿。[password] 为明文，仅存在于内存中，
/// 落盘前会被转换为 MD5（kosync 协议本身也只传 MD5）。
class KoreaderSyncConfigDraft {
  const KoreaderSyncConfigDraft({
    required this.serverUrl,
    required this.username,
    required this.password,
    this.checksumMethod = KoreaderChecksumMethod.partialMd5,
    this.allowInsecurePrivateHttp = false,
  });

  final String serverUrl;
  final String username;
  final String password;
  final KoreaderChecksumMethod checksumMethod;
  final bool allowInsecurePrivateHttp;

  KoreaderSyncConfiguration withoutPassword({
    bool autoSync = true,
    bool syncOnOpen = true,
    bool syncOnSave = true,
    bool preferLocalOnFirstSync = false,
    String? deviceName,
  }) => KoreaderSyncConfiguration(
    serverUrl: serverUrl,
    username: username,
    checksumMethod: checksumMethod,
    allowInsecurePrivateHttp: allowInsecurePrivateHttp,
    autoSync: autoSync,
    syncOnOpen: syncOnOpen,
    syncOnSave: syncOnSave,
    preferLocalOnFirstSync: preferLocalOnFirstSync,
    deviceName: deviceName,
  );
}

class KoreaderSyncConfiguration {
  const KoreaderSyncConfiguration({
    required this.serverUrl,
    required this.username,
    this.checksumMethod = KoreaderChecksumMethod.partialMd5,
    this.allowInsecurePrivateHttp = false,
    this.autoSync = true,
    this.syncOnOpen = true,
    this.syncOnSave = true,
    this.preferLocalOnFirstSync = false,
    this.deviceName,
  });

  final String serverUrl;
  final String username;
  final KoreaderChecksumMethod checksumMethod;
  final bool allowInsecurePrivateHttp;
  final bool autoSync;
  final bool syncOnOpen;
  final bool syncOnSave;

  /// 首次同步（本地尚无同步记录）遇到远端已有进度时，默认采纳远端。
  /// 打开此项则改为本地优先，适合本地已经读到一半、不想被远端回退的场景。
  final bool preferLocalOnFirstSync;

  /// 上报给服务器的设备名，仅用于在 KOReader 侧展示「进度来自哪台设备」。
  final String? deviceName;

  Map<String, Object?> toJson() => {
    'server_url': serverUrl,
    'username': username,
    'checksum_method': checksumMethod.storageValue,
    'allow_insecure_private_http': allowInsecurePrivateHttp,
    'auto_sync': autoSync,
    'sync_on_open': syncOnOpen,
    'sync_on_save': syncOnSave,
    'prefer_local_on_first_sync': preferLocalOnFirstSync,
    if (deviceName != null) 'device_name': deviceName,
  };

  factory KoreaderSyncConfiguration.fromJson(Map<String, dynamic> json) =>
      KoreaderSyncConfiguration(
        serverUrl: json['server_url'] as String,
        username: json['username'] as String,
        checksumMethod: KoreaderChecksumMethod.fromStorage(
          json['checksum_method'] as String?,
        ),
        allowInsecurePrivateHttp:
            json['allow_insecure_private_http'] as bool? ?? false,
        autoSync: json['auto_sync'] as bool? ?? true,
        syncOnOpen: json['sync_on_open'] as bool? ?? true,
        syncOnSave: json['sync_on_save'] as bool? ?? true,
        preferLocalOnFirstSync:
            json['prefer_local_on_first_sync'] as bool? ?? false,
        deviceName: json['device_name'] as String?,
      );

  KoreaderSyncConfiguration copyWith({
    String? serverUrl,
    String? username,
    KoreaderChecksumMethod? checksumMethod,
    bool? allowInsecurePrivateHttp,
    bool? autoSync,
    bool? syncOnOpen,
    bool? syncOnSave,
    bool? preferLocalOnFirstSync,
    String? deviceName,
  }) => KoreaderSyncConfiguration(
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    checksumMethod: checksumMethod ?? this.checksumMethod,
    allowInsecurePrivateHttp:
        allowInsecurePrivateHttp ?? this.allowInsecurePrivateHttp,
    autoSync: autoSync ?? this.autoSync,
    syncOnOpen: syncOnOpen ?? this.syncOnOpen,
    syncOnSave: syncOnSave ?? this.syncOnSave,
    preferLocalOnFirstSync:
        preferLocalOnFirstSync ?? this.preferLocalOnFirstSync,
    deviceName: deviceName ?? this.deviceName,
  );
}

/// 服务器返回的单本书进度记录。
///
/// `GET /syncs/progress/{document}` 的响应形如
/// `{document, progress, percentage, device, device_id, timestamp}`。
/// [timestamp] 可空：部分自建服务端不返回该字段，此时只能退化为「远端存在即视为较新」。
class KoreaderRemoteProgress {
  const KoreaderRemoteProgress({
    required this.document,
    required this.progress,
    required this.percentage,
    this.device = '',
    this.deviceId = '',
    this.timestamp,
  });

  final String document;

  /// KOReader 的原始进度字段。分页文档是页码字符串，可重排文档（EPUB）是
  /// crengine XPointer。EPUB 同步会用它精确复原落点；其余情形仅作展示与降级。
  final String progress;
  final double percentage;
  final String device;
  final String deviceId;
  final double? timestamp;

  static KoreaderRemoteProgress? tryParse(Object? body) {
    if (body is! Map) return null;
    final document = body['document'];
    final percentage = body['percentage'];
    if (document is! String || document.isEmpty || percentage is! num) {
      return null;
    }
    return KoreaderRemoteProgress(
      document: document,
      progress: body['progress']?.toString() ?? '',
      percentage: percentage.toDouble(),
      device: body['device']?.toString() ?? '',
      deviceId: body['device_id']?.toString() ?? '',
      timestamp: body['timestamp'] is num
          ? (body['timestamp'] as num).toDouble()
          : null,
    );
  }
}

class KoreaderConnectionTestResult {
  const KoreaderConnectionTestResult({required this.success, this.errorCode});

  final bool success;
  final KoreaderSyncErrorCode? errorCode;
}

class KoreaderSyncRunResult {
  const KoreaderSyncRunResult({
    this.pushed = 0,
    this.pulled = 0,
    this.skipped = 0,
    this.failed = 0,
  });

  final int pushed;
  final int pulled;
  final int skipped;
  final int failed;

  bool get hasFailures => failed > 0;
  int get total => pushed + pulled + skipped + failed;
}
