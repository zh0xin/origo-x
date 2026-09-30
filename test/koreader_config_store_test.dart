import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/koreader/koreader_config_store.dart';
import 'package:xxread/services/sync/koreader/koreader_models.dart';

class _FakeSecretStorage implements SyncSecretStorage {
  final Map<String, String> values = <String, String>{};
  bool throwOnWrite = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (throwOnWrite) throw StateError('secure storage unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _FakePreferences implements SyncPreferences {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late _FakeSecretStorage secrets;
  late _FakePreferences prefs;
  late KoreaderConfigStore store;

  setUp(() {
    secrets = _FakeSecretStorage();
    prefs = _FakePreferences();
    store = KoreaderConfigStore(secretStorage: secrets, preferences: prefs);
  });

  const configuration = KoreaderSyncConfiguration(
    serverUrl: 'https://sync.koreader.rocks',
    username: 'alice',
  );

  group('保存与读取', () {
    test('保存后可以读回配置与凭据', () async {
      await store.save(configuration, 'md5hex');

      final credentials = await store.readCredentials();
      expect(credentials, isNotNull);
      expect(credentials!.configuration.serverUrl, configuration.serverUrl);
      expect(credentials.configuration.username, 'alice');
      expect(credentials.passwordMd5, 'md5hex');
    });

    test('只落 MD5，不落明文密码', () async {
      final md5 = koreaderPasswordHash('hunter2');
      await store.save(configuration, md5);

      expect(secrets.values.values, contains(md5));
      expect(secrets.values.values.join(), isNot(contains('hunter2')));
      expect(prefs.values.values.join(), isNot(contains('hunter2')));
    });

    test('未配置时返回 null', () async {
      expect(await store.readConfiguration(), isNull);
      expect(await store.readCredentials(), isNull);
    });

    test('有配置但缺少凭据时返回 null', () async {
      await store.save(configuration, 'md5hex');
      secrets.values.clear();

      expect(await store.readConfiguration(), isNotNull);
      expect(await store.readCredentials(), isNull);
    });

    test('配置损坏时视为未配置，不抛异常', () async {
      prefs.values[KoreaderConfigStore.configurationKey] = '{not valid json';
      expect(await store.readConfiguration(), isNull);
    });

    test('安全存储写入失败时不留下孤立配置', () async {
      secrets.throwOnWrite = true;

      await expectLater(
        store.save(configuration, 'md5hex'),
        throwsA(
          isA<KoreaderSyncFailure>().having(
            (failure) => failure.code,
            'code',
            KoreaderSyncErrorCode.secureStorage,
          ),
        ),
      );
      expect(await store.readConfiguration(), isNull);
    });
  });

  group('清除', () {
    test('清除后配置与凭据均不可读', () async {
      await store.save(configuration, 'md5hex');
      await store.clear();

      expect(await store.readConfiguration(), isNull);
      expect(await store.readCredentials(), isNull);
      expect(secrets.values, isEmpty);
    });

    test('清除不删除设备标识，重新登录时设备身份保持稳定', () async {
      await store.saveDeviceId('XXR1234567890ABC');
      await store.save(configuration, 'md5hex');

      await store.clear();

      expect(await store.readDeviceId(), 'XXR1234567890ABC');
    });
  });

  group('设备标识与同步时间', () {
    test('设备标识可读写', () async {
      expect(await store.readDeviceId(), isNull);
      await store.saveDeviceId('XXRABC');
      expect(await store.readDeviceId(), 'XXRABC');
    });

    test('同步时间可读写且保留毫秒', () async {
      expect(await store.readLastSyncAt(), isNull);
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000123);
      await store.saveLastSyncAt(now);

      expect(await store.readLastSyncAt(), now);
    });

    test('同步时间损坏时返回 null', () async {
      prefs.values[KoreaderConfigStore.lastSyncAtKey] = 'not-a-number';
      expect(await store.readLastSyncAt(), isNull);
    });
  });

  group('validateKoreaderConfiguration', () {
    test('接受 https 地址', () {
      expect(
        validateKoreaderConfiguration(configuration, passwordMd5: 'md5'),
        Uri.parse('https://sync.koreader.rocks'),
      );
    });

    test('拒绝明文 http 公网地址', () {
      expect(
        () => validateKoreaderConfiguration(
          const KoreaderSyncConfiguration(
            serverUrl: 'http://sync.example.com',
            username: 'alice',
          ),
          passwordMd5: 'md5',
        ),
        throwsA(
          isA<KoreaderSyncFailure>().having(
            (failure) => failure.code,
            'code',
            KoreaderSyncErrorCode.insecureConnection,
          ),
        ),
      );
    });

    test('显式允许时接受私网明文 http（自建服务场景）', () {
      expect(
        validateKoreaderConfiguration(
          const KoreaderSyncConfiguration(
            serverUrl: 'http://192.168.1.10:8080',
            username: 'alice',
            allowInsecurePrivateHttp: true,
          ),
          passwordMd5: 'md5',
        ),
        Uri.parse('http://192.168.1.10:8080'),
      );
      expect(
        validateKoreaderConfiguration(
          const KoreaderSyncConfiguration(
            serverUrl: 'http://localhost:8080',
            username: 'alice',
            allowInsecurePrivateHttp: true,
          ),
          passwordMd5: 'md5',
        ).host,
        'localhost',
      );
    });

    test('拒绝缺少用户名', () {
      expect(
        () => validateKoreaderConfiguration(
          const KoreaderSyncConfiguration(
            serverUrl: 'https://sync.koreader.rocks',
            username: '   ',
          ),
          passwordMd5: 'md5',
        ),
        throwsA(isA<KoreaderSyncFailure>()),
      );
    });

    test('拒绝空凭据', () {
      expect(
        () => validateKoreaderConfiguration(configuration, passwordMd5: ''),
        throwsA(isA<KoreaderSyncFailure>()),
      );
    });

    test('拒绝内嵌凭据的地址', () {
      expect(
        () => validateKoreaderConfiguration(
          const KoreaderSyncConfiguration(
            serverUrl: 'https://alice:pw@sync.koreader.rocks',
            username: 'alice',
          ),
          passwordMd5: 'md5',
        ),
        throwsA(
          isA<KoreaderSyncFailure>().having(
            (failure) => failure.code,
            'code',
            KoreaderSyncErrorCode.invalidConfiguration,
          ),
        ),
      );
    });

    test('拒绝非 http(s) 协议', () {
      expect(
        () => validateKoreaderConfiguration(
          const KoreaderSyncConfiguration(
            serverUrl: 'ftp://sync.koreader.rocks',
            username: 'alice',
          ),
          passwordMd5: 'md5',
        ),
        throwsA(isA<KoreaderSyncFailure>()),
      );
    });
  });

  group('koreaderPasswordHash', () {
    test('与 md5sum 结果一致', () {
      // echo -n "test" | md5sum
      expect(koreaderPasswordHash('test'), '098f6bcd4621d373cade4e832627b4f6');
    });

    test('输出小写十六进制', () {
      final hash = koreaderPasswordHash('SomePassword123');
      expect(hash, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });
}
