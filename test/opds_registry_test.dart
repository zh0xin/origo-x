import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/opds/models/opds_catalog.dart';
import 'package:xxread/opds/models/opds_feed.dart';
import 'package:xxread/opds/services/opds_download_service.dart';
import 'package:xxread/opds/services/opds_registry.dart';
import 'package:xxread/core/reader/canonical_locator.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';

class _FakePreferences implements SyncPreferences {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
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

void main() {
  late _FakePreferences prefs;
  late _FakeSecretStorage secrets;
  late OpdsRegistry registry;

  setUp(() {
    prefs = _FakePreferences();
    secrets = _FakeSecretStorage();
    registry = OpdsRegistry(preferences: prefs, secretStorage: secrets);
  });

  OpdsCatalog _catalog({
    String id = 'opds1',
    String url = 'https://catalog.example.org/opds',
    String title = 'Catalog',
    bool enabled = true,
  }) => OpdsCatalog(
    id: id,
    url: Uri.parse(url),
    title: title,
    enabled: enabled,
    addedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );

  group('OpdsRegistry', () {
    test('初始状态为空列表', () async {
      expect(await registry.load(), isEmpty);
    });

    test('新增后可读回', () async {
      await registry.upsert(_catalog(), password: 'secret');

      final catalogs = await registry.load();
      expect(catalogs, hasLength(1));
      expect(catalogs.single.title, 'Catalog');
      expect(
        catalogs.single.url.toString(),
        'https://catalog.example.org/opds',
      );
    });

    test('同 id 覆盖而非追加', () async {
      await registry.upsert(_catalog());
      await registry.upsert(_catalog(title: 'Renamed'));

      final catalogs = await registry.load();
      expect(catalogs, hasLength(1));
      expect(catalogs.single.title, 'Renamed');
    });

    test('密码存入安全存储而非 JSON', () async {
      await registry.upsert(_catalog(), password: 'secret');

      final raw = prefs.values[OpdsRegistry.storageKey]!;
      expect(raw, isNot(contains('secret')));
      expect(await registry.readPassword(_catalog()), 'secret');
    });

    test('未提供密码时保留既有凭据', () async {
      await registry.upsert(_catalog(), password: 'secret');
      await registry.upsert(_catalog(title: 'Renamed'));

      expect(await registry.readPassword(_catalog()), 'secret');
    });

    test('切换启用状态', () async {
      await registry.upsert(_catalog());
      await registry.setEnabled(_catalog(), false);

      expect((await registry.load()).single.enabled, isFalse);
    });

    test('移除目录并清除其凭据', () async {
      await registry.upsert(_catalog(), password: 'secret');
      await registry.remove('opds1');

      expect(await registry.load(), isEmpty);
      expect(secrets.values.values, isEmpty);
    });

    test('损坏条目被跳过而不影响其余目录', () async {
      await registry.upsert(_catalog(id: 'good', title: 'Good'));
      // 手工掺入一个非法条目。
      final raw = prefs.values[OpdsRegistry.storageKey]!;
      prefs.values[OpdsRegistry.storageKey] =
          raw.substring(0, raw.length - 1) + ',{"id":"bad","url":"nope"}]';

      final catalogs = await registry.load();
      expect(catalogs, hasLength(1));
      expect(catalogs.single.id, 'good');
    });

    test('存储内容损坏时返回空列表而非抛异常', () async {
      prefs.values[OpdsRegistry.storageKey] = '{not json';
      expect(await registry.load(), isEmpty);
    });

    test('生成的目录 id 唯一', () {
      final ids = <String>{
        for (var i = 0; i < 50; i++) OpdsRegistry.newCatalogId(),
      };
      expect(ids, hasLength(50));
    });
  });

  group('OpdsCatalog 模型', () {
    test('JSON 往返保持字段', () {
      final catalog = _catalog().copyWith(
        authUsername: 'alice',
        allowInsecurePrivateHttp: true,
      );
      final restored = OpdsCatalog.fromJson(catalog.toJson())!;

      expect(restored.id, catalog.id);
      expect(restored.title, catalog.title);
      expect(restored.authUsername, 'alice');
      expect(restored.allowInsecurePrivateHttp, isTrue);
      expect(restored.addedAt, catalog.addedAt);
    });

    test('缺少用户名的目录不需要认证', () {
      expect(_catalog().requiresAuth, isFalse);
      expect(_catalog().copyWith(authUsername: 'alice').requiresAuth, isTrue);
    });

    test('拒绝非 http(s) 地址', () {
      expect(
        OpdsCatalog.fromJson(const {
          'id': 'x',
          'url': 'ftp://example.org/opds',
          'title': 'T',
        }),
        isNull,
      );
    });

    test('拒绝缺少必填字段的条目', () {
      expect(
        OpdsCatalog.fromJson(const {'id': 'x', 'url': 'https://a.com'}),
        isNull,
      );
      expect(
        OpdsCatalog.fromJson(const {'url': 'https://a.com', 'title': 'T'}),
        isNull,
      );
    });
  });

  group('格式推断', () {
    test('优先使用 content-type', () {
      final link = OpdsLink(
        rel: 'http://opds-spec.org/acquisition',
        href: Uri.parse('https://a.com/file'),
        type: 'application/pdf',
      );
      expect(
        OpdsDownloadService.resolveFormat(
          link,
          contentType: 'application/epub+zip',
        ),
        BookFormat.epub,
      );
    });

    test('content-type 缺失时用链接 type', () {
      final link = OpdsLink(
        rel: 'http://opds-spec.org/acquisition',
        href: Uri.parse('https://a.com/file'),
        type: 'application/epub+zip',
      );
      expect(OpdsDownloadService.resolveFormat(link), BookFormat.epub);
    });

    test('两者都不可用时回退到 URL 后缀', () {
      final link = OpdsLink(
        rel: 'http://opds-spec.org/acquisition',
        href: Uri.parse('https://a.com/book.mobi'),
        type: 'application/octet-stream',
      );
      expect(OpdsDownloadService.resolveFormat(link), BookFormat.mobi);
    });

    test('无法判断时返回 unknown（不可导入）', () {
      final link = OpdsLink(
        rel: 'http://opds-spec.org/acquisition',
        href: Uri.parse('https://a.com/download'),
        type: 'application/octet-stream',
      );
      final format = OpdsDownloadService.resolveFormat(link);
      expect(format, BookFormat.unknown);
      expect(format.isImportEnabled, isFalse);
    });

    test('octet-stream 不掩盖 URL 后缀', () {
      final link = OpdsLink(
        rel: 'http://opds-spec.org/acquisition',
        href: Uri.parse('https://a.com/book.epub'),
        type: 'application/octet-stream',
      );
      expect(OpdsDownloadService.resolveFormat(link), BookFormat.epub);
    });

    test('cbr 不可导入', () {
      final link = OpdsLink(
        rel: 'http://opds-spec.org/acquisition',
        href: Uri.parse('https://a.com/book.cbr'),
      );
      expect(OpdsDownloadService.resolveFormat(link).isImportEnabled, isFalse);
    });
  });
}
