import 'package:flutter/material.dart';
import 'package:xxread/opds/models/opds_catalog.dart';
import 'package:xxread/opds/services/opds_client.dart';
import 'package:xxread/opds/services/opds_parser.dart';
import 'package:xxread/opds/services/opds_registry.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';

/// 添加或编辑一个 OPDS 目录。
///
/// 保存前先「测试」——真正拉取一次根 feed，确认地址可达且是合法 OPDS，
/// 避免把打不开的目录写进列表。
class OpdsCatalogEditPage extends StatefulWidget {
  const OpdsCatalogEditPage({super.key, required this.registry, this.existing});

  final OpdsRegistry registry;
  final OpdsCatalog? existing;

  @override
  State<OpdsCatalogEditPage> createState() => _OpdsCatalogEditPageState();
}

class _OpdsCatalogEditPageState extends State<OpdsCatalogEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController;
  late final TextEditingController _titleController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;

  bool _obscurePassword = true;
  bool _allowPrivateHttp = false;
  bool _testing = false;
  bool _saving = false;
  String? _testError;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _urlController = TextEditingController(
      text: existing?.url.toString() ?? '',
    );
    _titleController = TextEditingController(text: existing?.title ?? '');
    _usernameController = TextEditingController(
      text: existing?.authUsername ?? '',
    );
    _passwordController = TextEditingController();
    _allowPrivateHttp = existing?.allowInsecurePrivateHttp ?? false;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Uri? get _parsedUrl {
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }

  /// 拉取根 feed 验证地址。返回解析出的标题，供「名称」留空时自动填充。
  Future<String?> _test() async {
    final uri = _parsedUrl;
    if (uri == null) {
      setState(() => _testError = context.l10n.opdsCatalogTestFailed);
      return null;
    }
    setState(() {
      _testing = true;
      _testError = null;
    });
    final client = OpdsClient(allowPrivateNetwork: _allowPrivateHttp);
    try {
      final bytes = await client.fetchFeedBytes(
        uri,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        allowInsecurePrivateHttp: _allowPrivateHttp,
      );
      final feed = OpdsParser.parse(bytes, baseUrl: uri);
      if (mounted) {
        setState(() {
          if (_titleController.text.trim().isEmpty) {
            _titleController.text = feed.title;
          }
        });
      }
      return feed.title;
    } catch (error) {
      if (mounted) {
        // 带出底层异常原文，便于定位具体失败原因。
        setState(
          () => _testError = '${context.l10n.opdsCatalogTestFailed}\n\n$error',
        );
      }
      return null;
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final uri = _parsedUrl;
    if (uri == null) return;

    setState(() => _saving = true);
    try {
      // 保存前强制验证一次，避免写入打不开的地址。
      final title = await _test();
      if (title == null) {
        setState(() => _saving = false);
        return;
      }
      final existing = widget.existing;
      final catalog = OpdsCatalog(
        id: existing?.id ?? OpdsRegistry.newCatalogId(),
        url: uri,
        title: _titleController.text.trim().isEmpty
            ? title
            : _titleController.text.trim(),
        enabled: existing?.enabled ?? true,
        addedAt: existing?.addedAt ?? DateTime.now(),
        authUsername: _usernameController.text.trim(),
        allowInsecurePrivateHttp: _allowPrivateHttp,
      );
      final password = _passwordController.text;
      await widget.registry.upsert(
        catalog,
        // 密码留空表示沿用已保存的凭据，避免编辑标题时清空密码。
        password: password.isEmpty ? null : password,
      );
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null ? l10n.opdsAddCatalog : l10n.opdsEditCatalog,
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: PageStyleHelper.backgroundGradient(context),
        ),
        child: SafeArea(
          top: false,
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
              children: [
                TextFormField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    labelText: l10n.opdsCatalogUrl,
                    hintText: 'https://standardebooks.org/feeds/opds',
                    prefixIcon: const Icon(Icons.link_outlined),
                  ),
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  validator: (value) {
                    final uri = Uri.tryParse(value?.trim() ?? '');
                    if (uri == null ||
                        !uri.hasAuthority ||
                        (uri.scheme != 'http' && uri.scheme != 'https')) {
                      return l10n.koreaderErrorInvalidConfiguration;
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _titleController,
                  decoration: InputDecoration(
                    labelText: l10n.opdsCatalogName,
                    prefixIcon: const Icon(Icons.label_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    labelText: l10n.opdsCatalogUsername,
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: l10n.opdsCatalogPassword,
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  obscureText: _obscurePassword,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: Text(l10n.opdsCatalogAllowPrivateHttp),
                  value: _allowPrivateHttp,
                  onChanged: (value) =>
                      setState(() => _allowPrivateHttp = value),
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: _testing || _saving ? null : _test,
                  icon: _testing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_find_outlined),
                  label: Text(l10n.opdsCatalogTest),
                ),
                if (_testError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _testError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(l10n.opdsAddCatalog),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
