// 文件说明：OPDS Atom feed 的解析结果模型。
// 技术要点：区分 navigation feed 与 acquisition feed；链接按 rel 归类。

/// feed 类型。
///
/// OPDS 1.2 用 `kind` 属性区分：导航型 feed 的条目指向子 feed，
/// 获取型 feed 的条目指向可下载的书籍文件。
enum OpdsFeedKind { navigation, acquisition }

/// Atom 链接。
class OpdsLink {
  const OpdsLink({
    required this.rel,
    required this.href,
    this.type,
    this.title,
  });

  /// 完整 rel（含命名空间），例如 `http://opds-spec.org/acquisition`。
  final String rel;
  final Uri href;
  final String? type;
  final String? title;

  /// rel 的最后一段，用于便捷比较（`http://opds-spec.org/image` → `image`）。
  String get relName {
    final trimmed = rel.trim();
    final separator = trimmed.lastIndexOf('/');
    if (separator < 0 || separator == trimmed.length - 1) return trimmed;
    return trimmed.substring(separator + 1);
  }

  bool get isAcquisition =>
      relName == 'acquisition' || relName == 'open-access';

  bool get isCover => relName == 'image' || relName.startsWith('image/');

  bool get isThumbnail =>
      relName == 'thumbnail' || relName == 'image/thumbnail';
}

/// feed 中的一个条目：导航分类，或一本可获取的书。
class OpdsEntry {
  const OpdsEntry({
    required this.id,
    required this.title,
    this.author = '',
    this.summary = '',
    this.updated,
    this.coverUrl,
    this.thumbnailUrl,
    this.links = const [],
  });

  final String id;
  final String title;
  final String author;
  final String summary;
  final DateTime? updated;
  final Uri? coverUrl;
  final Uri? thumbnailUrl;
  final List<OpdsLink> links;

  /// 可下载的书籍文件链接。导航条目为空。
  List<OpdsLink> get acquisitions =>
      links.where((link) => link.isAcquisition).toList(growable: false);

  /// 是否为指向子 feed 的导航条目。
  bool get isNavigation => acquisitions.isEmpty;
}

/// 解析后的 feed。
class OpdsFeed {
  const OpdsFeed({
    required this.selfUrl,
    required this.kind,
    required this.title,
    this.entries = const [],
    this.nextUrl,
    this.previousUrl,
    this.startUrl,
    this.upUrl,
    this.searchUrl,
    this.searchTemplate,
  });

  final Uri selfUrl;
  final OpdsFeedKind kind;
  final String title;
  final List<OpdsEntry> entries;

  /// `rel="next"`：下一页。
  final Uri? nextUrl;

  /// `rel="prev"`：上一页。
  final Uri? previousUrl;

  /// `rel="start"`：feed 根。
  final Uri? startUrl;

  /// `rel="up"`：上一级分类。
  final Uri? upUrl;

  /// `rel="search"`。本期不实现搜索 UI，仅保留以便后续接入 OpenSearch。
  final Uri? searchUrl;
  final String? searchTemplate;

  bool get hasEntries => entries.isNotEmpty;

  bool get hasNextPage => nextUrl != null;

  bool get hasPreviousPage => previousUrl != null;
}
