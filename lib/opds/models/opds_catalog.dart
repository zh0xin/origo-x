// 文件说明：OPDS 目录的注册信息模型。
// 技术要点：独立于 ORSP/Legado 书源体系；密码不入库，只存安全存储的键名。

/// 一个已注册的 OPDS 目录。
class OpdsCatalog {
  const OpdsCatalog({
    required this.id,
    required this.url,
    required this.title,
    this.enabled = true,
    required this.addedAt,
    this.authUsername = '',
    this.allowInsecurePrivateHttp = false,
  });

  /// 稳定标识。仅用于安全存储中定位密码，不参与网络请求。
  final String id;
  final Uri url;
  final String title;
  final bool enabled;
  final DateTime addedAt;

  /// HTTP Basic 认证用户名；为空表示该目录不需要认证。
  final String authUsername;

  /// 是否允许对私网/本机目录使用明文 HTTP（自建 Calibre-Web 等场景）。
  final bool allowInsecurePrivateHttp;

  bool get requiresAuth => authUsername.isNotEmpty;

  Map<String, Object?> toJson() => {
    'id': id,
    'url': url.toString(),
    'title': title,
    'enabled': enabled,
    'added_at': addedAt.toIso8601String(),
    'auth_username': authUsername,
    'allow_insecure_private_http': allowInsecurePrivateHttp,
  };

  /// 从持久化数据还原。返回 null 表示该条目已损坏，应跳过而不是让整个目录列表不可用。
  static OpdsCatalog? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final url = json['url'];
    final title = json['title'];
    if (id is! String || id.isEmpty) return null;
    if (title is! String || title.isEmpty) return null;
    if (url is! String || url.isEmpty) return null;
    final parsed = Uri.tryParse(url);
    if (parsed == null ||
        !parsed.hasAuthority ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return null;
    }
    final addedAt = DateTime.tryParse(json['added_at'] as String? ?? '');
    return OpdsCatalog(
      id: id,
      url: parsed,
      title: title,
      enabled: json['enabled'] as bool? ?? true,
      addedAt: addedAt ?? DateTime.now(),
      authUsername: json['auth_username'] as String? ?? '',
      allowInsecurePrivateHttp:
          json['allow_insecure_private_http'] as bool? ?? false,
    );
  }

  OpdsCatalog copyWith({
    Uri? url,
    String? title,
    bool? enabled,
    String? authUsername,
    bool? allowInsecurePrivateHttp,
  }) => OpdsCatalog(
    id: id,
    url: url ?? this.url,
    title: title ?? this.title,
    enabled: enabled ?? this.enabled,
    addedAt: addedAt,
    authUsername: authUsername ?? this.authUsername,
    allowInsecurePrivateHttp:
        allowInsecurePrivateHttp ?? this.allowInsecurePrivateHttp,
  );
}
