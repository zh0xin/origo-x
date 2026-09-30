// 文件说明：OPDS 目录网络客户端——有界 GET、手动重定向、SSRF 防护、可选 Basic 认证。
// 技术要点：复用 BookSourceNetworkPolicy（DNS 绑定 + 私网拦截 + 拦截 HTTPS→HTTP 降级），
// 与书源客户端保持同一套网络安全边界。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../book_sources/protocol/book_source_protocol.dart';
import '../../book_sources/services/book_source_network_policy.dart';

class OpdsClient {
  OpdsClient({
    bool allowPrivateNetwork = false,
    BookSourceNetworkPolicy? networkPolicy,
    Dio? dio,
  }) : _networkPolicy =
           networkPolicy ??
           BookSourceNetworkPolicy(allowPrivateNetwork: allowPrivateNetwork) {
    _dio =
        dio ??
        (Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 20),
              headers: const {'Accept': _feedAcceptHeader},
            ),
          )
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: _networkPolicy.createPinnedHttpClient,
          ));
  }

  /// 目录站点常见的 media type 组合。
  static const String _feedAcceptHeader =
      'application/atom+xml;type=entry;profile=opds-catalog,'
      'application/atom+xml;type=feed;profile=opds-catalog,'
      'application/atom+xml,application/xml;q=0.9,*/*;q=0.8';

  static const int maxFeedBytes = 8 * 1024 * 1024;
  static const int maxDownloadBytes = 64 * 1024 * 1024;
  static const int _maxRedirects = 5;

  final BookSourceNetworkPolicy _networkPolicy;
  late final Dio _dio;

  void close() => _dio.close(force: true);

  /// 抓取一个 feed 的原始字节。
  Future<Uint8List> fetchFeedBytes(
    Uri url, {
    required String? username,
    required String? password,
    required bool allowInsecurePrivateHttp,
  }) => _getBounded(
    url,
    maxBytes: maxFeedBytes,
    username: username,
    password: password,
    allowInsecurePrivateHttp: allowInsecurePrivateHttp,
  );

  /// 下载一个可获取的书籍文件。
  Future<Uint8List> downloadBytes(
    Uri url, {
    required String? username,
    required String? password,
    required bool allowInsecurePrivateHttp,
    BookDownloadProgress? onProgress,
  }) => _getBounded(
    url,
    maxBytes: maxDownloadBytes,
    username: username,
    password: password,
    allowInsecurePrivateHttp: allowInsecurePrivateHttp,
    onProgress: onProgress,
  );

  Future<Uint8List> _getBounded(
    Uri url, {
    required int maxBytes,
    required String? username,
    required String? password,
    required bool allowInsecurePrivateHttp,
    BookDownloadProgress? onProgress,
  }) async {
    // 允许明文 HTTP 时另建一个宽松策略实例；默认策略拒绝私网与回环。
    final policy = allowInsecurePrivateHttp
        ? BookSourceNetworkPolicy(allowPrivateNetwork: true)
        : _networkPolicy;

    var current = url;
    for (var redirects = 0; redirects <= _maxRedirects; redirects++) {
      await policy.validate(current);
      final cancelToken = CancelToken();
      try {
        final response = await _dio.getUri<List<int>>(
          current,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: false,
            headers: _authHeaders(username, password),
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
          ),
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
            if (received > maxBytes || total > maxBytes) {
              cancelToken.cancel('OPDS response exceeds $maxBytes bytes.');
            }
            onProgress?.call(received, total < 0 ? null : total);
          },
        );
        final status = response.statusCode ?? 0;
        if (status < 300) {
          final bytes = Uint8List.fromList(response.data ?? const <int>[]);
          if (bytes.length > maxBytes) {
            throw const BookSourceProtocolException(
              'OPDS response exceeded the allowed size.',
            );
          }
          return bytes;
        }
        if (redirects == _maxRedirects) {
          throw const BookSourceProtocolException(
            'OPDS catalog redirected too many times.',
          );
        }
        current = BookSourceNetworkPolicy.redirectTarget(
          current,
          response.headers.value(HttpHeaders.locationHeader),
        );
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) {
          throw const BookSourceProtocolException(
            'OPDS response exceeded the allowed size.',
          );
        }
        final underlying = error.error;
        throw BookSourceProtocolException(
          'OPDS request failed [${error.type.name}]: '
          '${error.message ?? ''}'
          '${underlying != null ? ' <- $underlying' : ''}',
        );
      }
    }
    throw const BookSourceProtocolException('OPDS request failed.');
  }

  Map<String, String> _authHeaders(String? username, String? password) {
    if (username == null || username.isEmpty) return const {};
    final credentials = '$username:${password ?? ''}';
    return {'Authorization': 'Basic ${base64Encode(utf8.encode(credentials))}'};
  }
}

typedef BookDownloadProgress = void Function(int received, int? total);
