// 文件说明：OPDS 目录注册表——SharedPreferences 存 JSON 数组，密码存安全存储。
// 技术要点：与 BookSourceRegistry 同形制（串行化写入 + 变更广播），
// 但完全独立，不影响 ORSP/Legado 书源。

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../../services/sync/secure_sync_config.dart';
import '../models/opds_catalog.dart';

class OpdsRegistry {
  OpdsRegistry({SyncPreferences? preferences, SyncSecretStorage? secretStorage})
    : _preferences = preferences ?? SharedSyncPreferences(),
      _secretStorage = secretStorage ?? FlutterSyncSecretStorage();

  static const String storageKey = 'open_reading.opds_catalogs_v1';
  static const String _passwordKeyPrefix = 'open_reading.opds.password.';

  final SyncPreferences _preferences;
  final SyncSecretStorage _secretStorage;

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();
  static Future<void> _mutationTail = Future<void>.value();

  Stream<void> get changes => _changesController.stream;

  Future<List<OpdsCatalog>> load() async {
    final raw = await _preferences.read(storageKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final catalogs = <OpdsCatalog>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final catalog = OpdsCatalog.fromJson(
          item.map((key, value) => MapEntry('$key', value)),
        );
        // 单条损坏不影响其余目录可用。
        if (catalog != null) catalogs.add(catalog);
      }
      return catalogs;
    } catch (_) {
      return const [];
    }
  }

  Future<void> upsert(OpdsCatalog catalog, {String? password}) =>
      _mutate(() async {
        // load() 可能返回 const 空列表，必须先复制成可变列表。
        final catalogs = (await load()).toList();
        final index = catalogs.indexWhere((item) => item.id == catalog.id);
        if (index >= 0) {
          catalogs[index] = catalog;
        } else {
          catalogs.add(catalog);
        }
        if (password != null) {
          await _secretStorage.write(
            '$_passwordKeyPrefix${catalog.id}',
            password,
          );
        }
        await _save(catalogs);
      });

  Future<void> setEnabled(OpdsCatalog catalog, bool enabled) =>
      upsert(catalog.copyWith(enabled: enabled));

  Future<void> remove(String id) => _mutate(() async {
    final catalogs = (await load())
        .where((catalog) => catalog.id != id)
        .toList(growable: false);
    try {
      await _secretStorage.delete('$_passwordKeyPrefix$id');
    } catch (_) {
      // 凭据清理失败不应阻止目录本身被移除。
    }
    await _save(catalogs);
  });

  Future<String?> readPassword(OpdsCatalog catalog) =>
      _secretStorage.read('$_passwordKeyPrefix${catalog.id}');

  /// 生成一个短且唯一的目录 id。无需密码学强度，仅用于本地键名与去重。
  static String newCatalogId() {
    final random = math.Random.secure();
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final buffer = StringBuffer('opds');
    for (var i = 0; i < 12; i++) {
      buffer.write(alphabet[random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  Future<T> _mutate<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    Future<void> run(_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }

    _mutationTail = _mutationTail.then<void>(run, onError: run);
    return completer.future;
  }

  Future<void> _save(List<OpdsCatalog> catalogs) async {
    await _preferences.write(
      storageKey,
      jsonEncode(catalogs.map((catalog) => catalog.toJson()).toList()),
    );
    _changesController.add(null);
  }
}
