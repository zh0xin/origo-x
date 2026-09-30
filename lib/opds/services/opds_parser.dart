// 文件说明：OPDS Atom feed 解析器。
// 技术要点：按命名空间查找元素，解析相对链接，限制条目与链接数量防止恶意响应。

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../models/opds_feed.dart';

/// 解析失败。调用方据此给出可读提示。
class OpdsParseException implements Exception {
  const OpdsParseException(this.message);
  final String message;

  @override
  String toString() => 'OpdsParseException: $message';
}

class OpdsParser {
  const OpdsParser._();

  static const String _atomNamespace = 'http://www.w3.org/2005/Atom';
  static const String _dcNamespace = 'http://purl.org/dc/elements/1.1/';

  /// 单个 feed 的条目数上限。正常目录远低于此值，超出说明响应异常。
  static const int maxEntries = 500;

  /// 单个条目的链接数上限。
  static const int maxLinksPerEntry = 50;

  static OpdsFeed parse(Uint8List bytes, {required Uri baseUrl}) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
    } catch (error) {
      throw OpdsParseException('The catalog response is not valid XML.');
    }

    final root = document.rootElement;
    if (root.name.local != 'feed') {
      throw OpdsParseException('The catalog response is not an OPDS feed.');
    }

    final feedTitle = _textOf(root, 'title') ?? baseUrl.host;
    final selfUrl = _linkByRel(root, baseUrl, 'self')?.href ?? baseUrl;
    final kind = _resolveKind(root, selfUrl);

    final entries = <OpdsEntry>[];
    var count = 0;
    for (final element in root.findAllElements(
      'entry',
      namespace: _atomNamespace,
    )) {
      if (count >= maxEntries) break;
      count++;
      final entry = _parseEntry(element, baseUrl);
      if (entry != null) entries.add(entry);
    }

    return OpdsFeed(
      selfUrl: selfUrl,
      kind: entries.any((entry) => entry.acquisitions.isNotEmpty)
          ? OpdsFeedKind.acquisition
          : kind,
      title: feedTitle,
      entries: entries,
      nextUrl: _linkByRel(root, baseUrl, 'next')?.href,
      previousUrl: _linkByRel(root, baseUrl, 'prev')?.href,
      startUrl: _linkByRel(root, baseUrl, 'start')?.href,
      upUrl: _linkByRel(root, baseUrl, 'up')?.href,
      searchUrl: _linkByRel(root, baseUrl, 'search')?.href,
      searchTemplate: _linkByRel(root, baseUrl, 'search')?.title,
    );
  }

  /// 依据 self 链接的 type 参数判定 feed 类型。
  ///
  /// type 缺失或无法识别时返回 null，交由调用方按条目内容推断。
  static OpdsFeedKind? declaredKind(XmlElement root, Uri selfUrl) {
    final selfLink = _linkByRel(root, selfUrl, 'self');
    final type = selfLink?.type ?? '';
    if (type.contains('type=entry') || type.contains('kind=acquisition')) {
      return OpdsFeedKind.acquisition;
    }
    if (type.contains('type=feed') || type.contains('kind=navigation')) {
      return OpdsFeedKind.navigation;
    }
    return null;
  }

  static OpdsFeedKind _resolveKind(XmlElement root, Uri selfUrl) {
    // OPDS 1.2 通过 self 链接的 type 参数声明 kind。
    // 缺失或无法识别时按条目内容推断：有获取链接即为获取型。
    final declared = declaredKind(root, selfUrl);
    if (declared != null) return declared;
    for (final entry in root.findAllElements(
      'entry',
      namespace: _atomNamespace,
    )) {
      if (_linksOf(entry, selfUrl).any((link) => link.isAcquisition)) {
        return OpdsFeedKind.acquisition;
      }
    }
    return OpdsFeedKind.navigation;
  }

  static OpdsEntry? _parseEntry(XmlElement element, Uri baseUrl) {
    final links = _linksOf(element, baseUrl);
    final id = _textOf(element, 'id') ?? _textOf(element, 'title') ?? '';
    final title = _textOf(element, 'title');
    if (title == null || title.isEmpty) return null;

    Uri? cover;
    Uri? thumbnail;
    for (final link in links) {
      if (link.isThumbnail) {
        thumbnail ??= link.href;
      } else if (link.isCover) {
        cover ??= link.href;
      }
    }
    return OpdsEntry(
      id: id.isEmpty ? title : id,
      title: title,
      author: _authorOf(element),
      summary: _textOf(element, 'summary') ?? _textOf(element, 'content') ?? '',
      updated: DateTime.tryParse(_textOf(element, 'updated') ?? ''),
      coverUrl: cover,
      thumbnailUrl: thumbnail,
      links: links,
    );
  }

  static String _authorOf(XmlElement element) {
    final atomAuthor = _textOf(element, 'author');
    if (atomAuthor != null && atomAuthor.isNotEmpty) return atomAuthor;
    for (final node in element.findAllElements(
      'creator',
      namespace: _dcNamespace,
    )) {
      final value = node.innerText.trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static List<OpdsLink> _linksOf(XmlElement element, Uri baseUrl) {
    final links = <OpdsLink>[];
    for (final node in element.findAllElements(
      'link',
      namespace: _atomNamespace,
    )) {
      if (links.length >= maxLinksPerEntry) break;
      final href = node.getAttribute('href');
      if (href == null || href.trim().isEmpty) continue;
      final resolved = _resolve(baseUrl, href);
      if (resolved == null) continue;
      links.add(
        OpdsLink(
          rel: node.getAttribute('rel') ?? '',
          href: resolved,
          type: node.getAttribute('type'),
          title: node.getAttribute('title'),
        ),
      );
    }
    return links;
  }

  static OpdsLink? _linkByRel(XmlElement element, Uri baseUrl, String relName) {
    for (final link in _linksOf(element, baseUrl)) {
      if (link.relName == relName) return link;
    }
    return null;
  }

  /// 按 RFC 3986 解析相对链接。
  ///
  /// 不对基址补尾部斜杠：`https://host/opds` 是一个资源而非目录，
  /// 补斜杠会让 `href="child"` 解析到 `/opds/child` 之外的错误位置。
  static Uri? _resolve(Uri baseUrl, String href) {
    final trimmed = href.trim();
    try {
      final resolved = baseUrl.resolve(trimmed);
      if (!resolved.hasAuthority) return null;
      if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
      return resolved;
    } on FormatException {
      return null;
    }
  }

  static String? _textOf(XmlElement parent, String localName) {
    for (final node in parent.childElements) {
      if (node.name.local != localName) continue;
      final value = node.innerText.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }
}
