// 文件说明：把 OPDS 获取链接下载为可交给导入管线的书籍来源。
// 技术要点：扩展名按「content-type → 链接 type → URL 后缀」依次推断；
// 结果交回既有 BookImportSource + 导入队列，不新增导入通道。

import 'package:path/path.dart' as p;

import '../../core/reader/canonical_locator.dart';
import '../../services/books/book_import_models.dart';
import '../models/opds_catalog.dart';
import '../models/opds_feed.dart';
import 'opds_client.dart';

class OpdsDownloadException implements Exception {
  const OpdsDownloadException(this.code, this.message);

  /// 稳定的错误标识，UI 层据此解析本地化文案。
  final String code;
  final String message;

  @override
  String toString() => 'OpdsDownloadException($code): $message';
}

class OpdsDownloadService {
  OpdsDownloadService({OpdsClient? client}) : _client = client ?? OpdsClient();

  final OpdsClient _client;

  /// 依据获取链接推断书籍格式。
  ///
  /// 目录站点给出的 `type` 往往比实际文件更笼统（例如统一标成
  /// `application/octet-stream`），因此按可靠性依次回退。
  static BookFormat resolveFormat(OpdsLink link, {String? contentType}) {
    final fromContentType = contentType == null || contentType.isEmpty
        ? BookFormat.unknown
        : BookFormat.fromMimeType(contentType);
    if (fromContentType != BookFormat.unknown) return fromContentType;

    final linkType = link.type;
    if (linkType != null && linkType.isNotEmpty) {
      final fromLinkType = BookFormat.fromMimeType(linkType);
      if (fromLinkType != BookFormat.unknown) return fromLinkType;
    }

    final fromUrl = BookFormat.fromFileExtension(
      p.extension(link.href.path).replaceFirst('.', ''),
    );
    if (fromUrl != BookFormat.unknown) return fromUrl;
    return BookFormat.unknown;
  }

  /// 下载一个获取链接并产出可导入的来源。
  Future<BookImportSource> download({
    required OpdsCatalog catalog,
    required String? catalogPassword,
    required OpdsEntry entry,
    required OpdsLink link,
    BookDownloadProgress? onProgress,
  }) async {
    final bytes = await _client.downloadBytes(
      link.href,
      username: catalog.requiresAuth ? catalog.authUsername : null,
      password: catalogPassword,
      allowInsecurePrivateHttp: catalog.allowInsecurePrivateHttp,
      onProgress: onProgress,
    );

    final format = resolveFormat(link, contentType: link.type);
    if (!format.isImportEnabled) {
      throw const OpdsDownloadException(
        'opds_unsupported_format',
        'The catalog entry format cannot be imported.',
      );
    }

    final extension = format.fileExtension();
    final fileName = _safeFileName(entry.title, extension);
    return BookImportSource.withBytes(
      id: 'opds:${link.href}',
      kind: BookImportSourceKind.opdsDownload,
      ownership: BookImportOwnership.externalCopy,
      displayName: fileName,
      extension: extension,
      locator: link.href.toString(),
      sizeBytes: bytes.length,
      bytes: bytes,
    );
  }

  /// 目录给出的标题可能包含路径分隔符或控制字符，直接当文件名不安全。
  static String _safeFileName(String title, String extension) {
    var base = title.trim();
    for (final separator in ['/', r'\', ':', '*', '?', '"', '<', '>', '|']) {
      base = base.replaceAll(separator, '_');
    }
    base = base.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (base.isEmpty) base = 'download';
    if (base.length > 120) base = base.substring(0, 120);
    return extension.isEmpty ? base : '$base.$extension';
  }

  void close() => _client.close();
}
