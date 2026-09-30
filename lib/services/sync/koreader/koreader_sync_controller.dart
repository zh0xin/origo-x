// 文件说明：KOReader 同步的 UI 门面（ChangeNotifier）。
// 技术要点：与 WebDavSyncController 同形制，暴露状态、错误与操作给设置页。

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'koreader_config_store.dart';
import 'koreader_models.dart';
import 'koreader_sync_service.dart';

class KoreaderSyncController extends ChangeNotifier {
  KoreaderSyncController({KoreaderSyncService? service})
    : _service = service ?? KoreaderSyncService();

  final KoreaderSyncService _service;

  KoreaderSyncStatus _status = KoreaderSyncStatus.unconfigured;
  KoreaderSyncErrorCode? _lastError;
  String? _lastErrorMessage;
  DateTime? _lastSuccessfulSync;
  KoreaderSyncRunResult? _lastResult;
  bool _busy = false;

  bool get isConfigured => _service.isConfigured;
  KoreaderSyncConfiguration? get configuration => _service.configuration;
  KoreaderSyncStatus get status => _status;
  KoreaderSyncErrorCode? get lastError => _lastError;
  String? get lastErrorMessage => _lastErrorMessage;
  DateTime? get lastSuccessfulSync => _lastSuccessfulSync;
  KoreaderSyncRunResult? get lastResult => _lastResult;
  bool get busy => _busy;
  bool get autoSync => _service.configuration?.autoSync ?? false;
  String? get serverUrl => _service.configuration?.serverUrl;
  String? get username => _service.configuration?.username;
  KoreaderChecksumMethod get checksumMethod =>
      _service.configuration?.checksumMethod ??
      KoreaderChecksumMethod.partialMd5;

  Future<void> initialize() async {
    await _service.initialize();
    _status = isConfigured
        ? KoreaderSyncStatus.idle
        : KoreaderSyncStatus.unconfigured;
    notifyListeners();
  }

  Future<KoreaderConnectionTestResult> testConnection(
    KoreaderSyncConfigDraft draft,
  ) async {
    _status = KoreaderSyncStatus.testing;
    _clearError();
    notifyListeners();
    try {
      final result = await _service.testConnection(
        configuration: draft.withoutPassword(),
        passwordMd5: koreaderPasswordHash(draft.password),
      );
      if (result.success) {
        _status = KoreaderSyncStatus.idle;
      } else {
        _status = KoreaderSyncStatus.failed;
        _lastError = result.errorCode ?? KoreaderSyncErrorCode.unknown;
      }
      return result;
    } on KoreaderSyncFailure catch (failure) {
      _status = KoreaderSyncStatus.failed;
      _lastError = failure.code;
      _lastErrorMessage = failure.message;
      return KoreaderConnectionTestResult(
        success: false,
        errorCode: failure.code,
      );
    } catch (_) {
      _status = KoreaderSyncStatus.failed;
      _lastError = KoreaderSyncErrorCode.network;
      return const KoreaderConnectionTestResult(
        success: false,
        errorCode: KoreaderSyncErrorCode.network,
      );
    } finally {
      notifyListeners();
    }
  }

  Future<void> configure(KoreaderSyncConfigDraft draft) async {
    await _service.save(
      configuration: draft.withoutPassword(
        autoSync: autoSync,
        syncOnOpen: _service.configuration?.syncOnOpen ?? true,
        syncOnSave: _service.configuration?.syncOnSave ?? true,
        preferLocalOnFirstSync:
            _service.configuration?.preferLocalOnFirstSync ?? false,
        deviceName: _service.configuration?.deviceName,
      ),
      passwordMd5: koreaderPasswordHash(draft.password),
    );
    _status = KoreaderSyncStatus.idle;
    _clearError();
    notifyListeners();
  }

  /// 在服务器上注册新账号，成功后直接以此凭据完成配置。
  Future<void> register(KoreaderSyncConfigDraft draft) async {
    await _service.registerAccount(
      serverUrl: draft.serverUrl,
      username: draft.username,
      password: draft.password,
      allowInsecurePrivateHttp: draft.allowInsecurePrivateHttp,
    );
    await configure(draft);
  }

  Future<void> clearConfiguration() async {
    await _service.clear();
    _status = KoreaderSyncStatus.unconfigured;
    _lastResult = null;
    _clearError();
    notifyListeners();
  }

  Future<void> setAutoSync(bool value) async {
    final configuration = _service.configuration;
    if (configuration == null) return;
    await _service.save(
      configuration: configuration.copyWith(autoSync: value),
      passwordMd5: _requireSecret(),
    );
    notifyListeners();
  }

  Future<void> setSyncOnOpen(bool value) async {
    await _updateConfiguration((config) => config.copyWith(syncOnOpen: value));
  }

  Future<void> setSyncOnSave(bool value) async {
    await _updateConfiguration((config) => config.copyWith(syncOnSave: value));
  }

  Future<void> setPreferLocalOnFirstSync(bool value) async {
    await _updateConfiguration(
      (config) => config.copyWith(preferLocalOnFirstSync: value),
    );
  }

  Future<void> setChecksumMethod(KoreaderChecksumMethod value) async {
    await _updateConfiguration(
      (config) => config.copyWith(checksumMethod: value),
    );
  }

  Future<void> _updateConfiguration(
    KoreaderSyncConfiguration Function(KoreaderSyncConfiguration) update,
  ) async {
    final configuration = _service.configuration;
    if (configuration == null) return;
    await _service.save(
      configuration: update(configuration),
      passwordMd5: _requireSecret(),
    );
    notifyListeners();
  }

  /// 同步凭据的 MD5。配置存在时必然已加载，缺失说明状态不一致。
  String _requireSecret() {
    final secret = _service.passwordMd5;
    if (secret == null || secret.isEmpty) {
      throw const KoreaderSyncFailure(
        KoreaderSyncErrorCode.secureStorage,
        'The KOReader sync credential is unavailable.',
      );
    }
    return secret;
  }

  Future<KoreaderSyncRunResult?> syncNow() async {
    if (!isConfigured || _busy) return null;
    _busy = true;
    _status = KoreaderSyncStatus.syncing;
    _clearError();
    notifyListeners();
    try {
      final result = await _service.pushDirtyBooks();
      _lastResult = result;
      _lastSuccessfulSync = DateTime.now();
      _status = result.hasFailures
          ? KoreaderSyncStatus.partialFailure
          : KoreaderSyncStatus.success;
      return result;
    } on KoreaderSyncFailure catch (failure) {
      _status = KoreaderSyncStatus.failed;
      _lastError = failure.code;
      _lastErrorMessage = failure.message;
      return null;
    } catch (error) {
      _status = KoreaderSyncStatus.failed;
      _lastError = KoreaderSyncErrorCode.unknown;
      _lastErrorMessage = '$error';
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _clearError() {
    _lastError = null;
    _lastErrorMessage = null;
  }
}
