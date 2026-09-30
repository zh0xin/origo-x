// 文件说明：KOReader 同步配置与凭据存储。
// 技术要点：配置存 SharedPreferences，凭据存安全存储；只落 MD5，不落明文密码。

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../secure_sync_config.dart';
import 'koreader_models.dart';

/// kosync 协议中密码只以 MD5 十六进制形式参与传输（`X-Auth-Key`），
/// 服务端注册时保存的也是该 MD5，因此客户端无需保留明文密码。
String koreaderPasswordHash(String password) =>
    md5.convert(utf8.encode(password)).toString();

class StoredKoreaderCredentials {
  const StoredKoreaderCredentials(this.configuration, this.passwordMd5);

  final KoreaderSyncConfiguration configuration;
  final String passwordMd5;
}

/// KOReader 同步配置存储。
///
/// 复用 [SyncSecretStorage] / [SyncPreferences] 抽象（与 WebDAV 同步同一套
/// 底层实现），但配置结构与键名完全独立，互不影响。
class KoreaderConfigStore {
  KoreaderConfigStore({
    SyncSecretStorage? secretStorage,
    SyncPreferences? preferences,
  }) : _secretStorage = secretStorage ?? FlutterSyncSecretStorage(),
       _preferences = preferences ?? SharedSyncPreferences();

  static const String configurationKey = 'open_reading.koreader.config_v1';
  static const String passwordMd5Key = 'open_reading.koreader.password_md5';
  static const String deviceIdKey = 'open_reading.koreader.device_id_v1';
  static const String lastSyncAtKey = 'open_reading.koreader.last_sync_at_v1';

  final SyncSecretStorage _secretStorage;
  final SyncPreferences _preferences;

  Future<KoreaderSyncConfiguration?> readConfiguration() async {
    final raw = await _preferences.read(configurationKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return KoreaderSyncConfiguration.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      // 配置损坏时视为未配置，而不是让整个同步入口崩溃。
      return null;
    }
  }

  Future<StoredKoreaderCredentials?> readCredentials() async {
    final configuration = await readConfiguration();
    if (configuration == null) return null;
    try {
      final passwordMd5 = await _secretStorage.read(passwordMd5Key);
      if (passwordMd5 == null || passwordMd5.isEmpty) return null;
      return StoredKoreaderCredentials(configuration, passwordMd5);
    } catch (_) {
      throw const KoreaderSyncFailure(
        KoreaderSyncErrorCode.secureStorage,
        'The KOReader sync credential could not be read from secure storage.',
      );
    }
  }

  Future<void> save(
    KoreaderSyncConfiguration configuration,
    String passwordMd5,
  ) async {
    validateKoreaderConfiguration(configuration, passwordMd5: passwordMd5);
    // 先写凭据：安全存储失败时绝不能留下「有配置但无凭据」的状态。
    try {
      await _secretStorage.write(passwordMd5Key, passwordMd5);
    } catch (_) {
      throw const KoreaderSyncFailure(
        KoreaderSyncErrorCode.secureStorage,
        'The KOReader sync credential could not be saved securely.',
      );
    }
    await _preferences.write(configurationKey, jsonEncode(configuration));
  }

  Future<String?> readDeviceId() => _preferences.read(deviceIdKey);

  Future<void> saveDeviceId(String deviceId) =>
      _preferences.write(deviceIdKey, deviceId);

  Future<DateTime?> readLastSyncAt() async {
    final raw = await _preferences.read(lastSyncAtKey);
    if (raw == null) return null;
    final millis = int.tryParse(raw);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> saveLastSyncAt(DateTime value) =>
      _preferences.write(lastSyncAtKey, '${value.millisecondsSinceEpoch}');

  Future<void> clear() async {
    try {
      await _secretStorage.delete(passwordMd5Key);
    } catch (_) {
      throw const KoreaderSyncFailure(
        KoreaderSyncErrorCode.secureStorage,
        'The KOReader sync credential could not be removed from secure storage.',
      );
    }
    await _preferences.delete(configurationKey);
    await _preferences.delete(lastSyncAtKey);
    // device_id 属于设备身份而非账号凭据，退出配置后保留，
    // 重新登录同一服务器时设备标识保持稳定。
  }
}

/// 校验 KOReader 同步配置，返回规范化后的服务器地址。
///
/// 与 [validateWebDavConfiguration] 同一策略：默认强制 HTTPS，
/// 仅当主机为本机/私网地址且用户显式允许时才放行明文 HTTP。
Uri validateKoreaderConfiguration(
  KoreaderSyncConfiguration configuration, {
  String? passwordMd5,
}) {
  final uri = Uri.tryParse(configuration.serverUrl.trim());
  if (uri == null ||
      !uri.hasScheme ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const KoreaderSyncFailure(
      KoreaderSyncErrorCode.invalidConfiguration,
      'Enter a valid KOReader sync server address without embedded credentials.',
    );
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const KoreaderSyncFailure(
      KoreaderSyncErrorCode.invalidConfiguration,
      'The KOReader sync server address must use HTTP or HTTPS.',
    );
  }
  if (configuration.username.trim().isEmpty ||
      (passwordMd5 != null && passwordMd5.isEmpty)) {
    throw const KoreaderSyncFailure(
      KoreaderSyncErrorCode.invalidConfiguration,
      'Server address, username, and password are required.',
    );
  }
  if (uri.scheme != 'https') {
    if (!isPrivateHost(uri.host) || !configuration.allowInsecurePrivateHttp) {
      throw const KoreaderSyncFailure(
        KoreaderSyncErrorCode.insecureConnection,
        'HTTPS is required. HTTP can only be explicitly enabled for a private or localhost address.',
      );
    }
  }
  return uri;
}
