// 文件说明：kosync 协议 HTTP 客户端。
// 技术要点：Dio + BookSourceNetworkPolicy 固定 DNS 客户端（防 SSRF/DNS 重绑定），
// 手动处理重定向以拦截 HTTPS→HTTP 降级；协议细节见 koreader/plugins/kosync.koplugin/api.json。

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../../book_sources/services/book_source_network_policy.dart';
import 'koreader_models.dart';

typedef KoreaderClientFactory =
    KoreaderClient Function(KoreaderSyncConfiguration configuration);

/// kosync 服务端要求客户端声明该 MIME，用于协议版本协商。
const String koreaderSyncAcceptHeader = 'application/vnd.koreader.v1+json';

class KoreaderClient {
  KoreaderClient({
    required this.configuration,
    required String passwordMd5,
    Dio? dio,
    BookSourceNetworkPolicy? networkPolicy,
  }) : _networkPolicy =
           networkPolicy ??
           BookSourceNetworkPolicy(
             allowPrivateNetwork: configuration.allowInsecurePrivateHttp,
           ) {
    _dio = dio ?? _buildDio(passwordMd5);
  }

  final KoreaderSyncConfiguration configuration;
  final BookSourceNetworkPolicy _networkPolicy;
  late final Dio _dio;

  Dio _buildDio(String passwordMd5) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 10),
        headers: {
          'Accept': koreaderSyncAcceptHeader,
          'Content-Type': 'application/json',
          'X-Auth-User': configuration.username,
          'X-Auth-Key': passwordMd5,
        },
      ),
    );
    // connectionFactory 在每次建连时解析并校验目标地址，
    // 因此即便发生重定向，新目标同样会被 SSRF 策略拦截。
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: _networkPolicy.createPinnedHttpClient,
    );
    return dio;
  }

  static const int _maxRedirects = 3;

  void close() => _dio.close(force: true);

  /// 拼接端点地址。自建服务常挂在子路径（如 `https://host/kosync`），
  /// 因此必须先把 base path 规范化为以 `/` 结尾再 resolve，
  /// 否则 `resolve('users/auth')` 会丢掉子路径。
  Uri _endpoint(String relativePath) {
    final base = Uri.parse(configuration.serverUrl.trim());
    final path = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: path).resolve(relativePath);
  }

  /// 校验账号密码。`GET /users/auth`，200 表示通过、401 表示凭据错误。
  Future<bool> authenticate() async {
    final response = await _send('GET', _endpoint('users/auth'));
    final status = response.statusCode ?? 0;
    if (status == 200) return true;
    if (status == 401 || status == 403) return false;
    throw _failureForStatus(response);
  }

  /// 注册新账号。`POST /users/create`，期望 201；402/409 表示用户名已被占用。
  ///
  /// kosync 服务端保存的就是 MD5，故此处直接提交 [passwordMd5]。
  Future<void> createAccount(String username, String passwordMd5) async {
    final response = await _send(
      'POST',
      _endpoint('users/create'),
      data: {'username': username, 'password': passwordMd5},
    );
    final status = response.statusCode ?? 0;
    if (status == 201 || status == 200) return;
    throw _failureForStatus(response);
  }

  /// 拉取某本书的远端进度。服务器无该书记录时返回 null（而非错误）。
  Future<KoreaderRemoteProgress?> getProgress(String document) async {
    final response = await _send(
      'GET',
      _endpoint('syncs/progress/${Uri.encodeComponent(document)}'),
    );
    final status = response.statusCode ?? 0;
    if (status == 404) return null;
    if (status != 200) throw _failureForStatus(response);
    final parsed = KoreaderRemoteProgress.tryParse(_asMap(response.data));
    if (parsed == null) {
      throw const KoreaderSyncFailure(
        KoreaderSyncErrorCode.malformedResponse,
        'The KOReader sync server returned an unexpected progress payload.',
      );
    }
    return parsed;
  }

  /// 上报进度。期望 200/202；返回服务器给出的时间戳（若响应中带有）。
  ///
  /// `progress` 字段按协议为**位置字符串**：EPUB 传 crengine XPointer（可与
  /// KOReader 精确对齐落点），无法生成时退化为百分比的定点表示。无论哪种，
  /// `percentage` 字段始终携带百分比，供跨设备的后写胜出与降级恢复使用。
  Future<double?> putProgress({
    required String document,
    required double percentage,
    required String device,
    required String deviceId,
    String? progress,
    Map<String, Object?>? metadata,
  }) async {
    final response = await _send(
      'PUT',
      _endpoint('syncs/progress'),
      data: {
        'document': document,
        'progress': progress ?? percentage.toStringAsFixed(6),
        'percentage': percentage,
        'device': device,
        'device_id': deviceId,
        if (metadata != null) 'metadata': metadata,
      },
    );
    final status = response.statusCode ?? 0;
    if (status != 200 && status != 202) throw _failureForStatus(response);
    final body = _asMap(response.data);
    final timestamp = body?['timestamp'];
    return timestamp is num ? timestamp.toDouble() : null;
  }

  /// 发送请求并按需手动跟随重定向。
  ///
  /// 关闭 Dio 的自动重定向，逐跳校验目标地址，并拒绝 HTTPS→HTTP 降级
  /// （与书源网络策略一致）。
  Future<Response<Object?>> _send(
    String method,
    Uri uri, {
    Object? data,
  }) async {
    var current = uri;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      await _networkPolicy.validate(current);
      final Response<Object?> response;
      try {
        response = await _dio.requestUri<Object?>(
          current,
          data: data,
          options: Options(
            method: method,
            followRedirects: false,
            // 4xx/5xx 交给调用方按端点语义解释，避免 Dio 先行抛错丢失状态码。
            validateStatus: (status) => status != null,
          ),
        );
      } on DioException catch (error) {
        throw _mapDioException(error);
      }
      final status = response.statusCode ?? 0;
      if (status < 300) return response;
      if (status >= 300 && status < 400) {
        if (hop == _maxRedirects) {
          throw const KoreaderSyncFailure(
            KoreaderSyncErrorCode.server,
            'The KOReader sync server redirected too many times.',
            statusCode: 310,
          );
        }
        try {
          current = BookSourceNetworkPolicy.redirectTarget(
            current,
            response.headers.value(HttpHeaders.locationHeader),
          );
        } on Object {
          throw const KoreaderSyncFailure(
            KoreaderSyncErrorCode.insecureConnection,
            'The KOReader sync server attempted an unsafe redirect.',
          );
        }
        continue;
      }
      return response;
    }
    throw const KoreaderSyncFailure(
      KoreaderSyncErrorCode.server,
      'The KOReader sync request failed.',
    );
  }

  Map<Object?, Object?>? _asMap(Object? data) {
    if (data is Map) return data;
    return null;
  }

  KoreaderSyncFailure _failureForStatus(Response<Object?> response) {
    final status = response.statusCode ?? 0;
    final serverMessage = _serverMessage(response.data);
    if (status == 401 || status == 403) {
      return KoreaderSyncFailure(
        KoreaderSyncErrorCode.authentication,
        serverMessage ?? 'The KOReader sync server rejected the credentials.',
        statusCode: status,
      );
    }
    if (status == 402 || status == 409) {
      return KoreaderSyncFailure(
        KoreaderSyncErrorCode.usernameTaken,
        serverMessage ?? 'That username is already registered.',
        statusCode: status,
      );
    }
    return KoreaderSyncFailure(
      KoreaderSyncErrorCode.server,
      serverMessage ?? 'The KOReader sync server returned HTTP $status.',
      statusCode: status,
    );
  }

  String? _serverMessage(Object? data) {
    if (data is Map) {
      final message = data['message'] ?? data['error'];
      if (message is String && message.trim().isNotEmpty) return message.trim();
    }
    return null;
  }

  KoreaderSyncFailure _mapDioException(DioException error) {
    final type = error.type;
    if (type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.receiveTimeout ||
        type == DioExceptionType.sendTimeout) {
      return const KoreaderSyncFailure(
        KoreaderSyncErrorCode.timeout,
        'The KOReader sync server did not respond in time.',
      );
    }
    if (type == DioExceptionType.badCertificate) {
      return const KoreaderSyncFailure(
        KoreaderSyncErrorCode.network,
        'The KOReader sync server certificate could not be verified.',
      );
    }
    return KoreaderSyncFailure(
      KoreaderSyncErrorCode.network,
      error.message ?? 'The KOReader sync server could not be reached.',
    );
  }
}
