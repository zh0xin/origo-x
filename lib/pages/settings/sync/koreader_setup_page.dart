import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xxread/services/sync/koreader/koreader_models.dart';
import 'package:xxread/services/sync/koreader/koreader_sync_controller.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';

import 'koreader_sync_translator.dart';

/// KOReader 同步配置表单：服务器地址、用户名、密码、校验方式、私网 HTTP。
///
/// 交互参照 [WebDavSetupPage]：测试通过后才允许保存；并提供「注册新账号」入口。
class KoreaderSetupPage extends StatefulWidget {
  const KoreaderSetupPage({super.key});

  @override
  State<KoreaderSetupPage> createState() => _KoreaderSetupPageState();
}

class _KoreaderSetupPageState extends State<KoreaderSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  var _obscurePassword = true;
  var _testing = false;
  var _saving = false;
  var _connectionVerified = false;
  KoreaderSyncErrorCode? _connectionError;
  KoreaderChecksumMethod _checksumMethod = KoreaderChecksumMethod.partialMd5;
  bool _allowPrivateHttp = false;

  @override
  void initState() {
    super.initState();
    final sync = context.read<KoreaderSyncController>();
    _serverController.text = sync.serverUrl ?? 'https://sync.koreader.rocks';
    _usernameController.text = sync.username ?? '';
    _checksumMethod = sync.checksumMethod;
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  KoreaderSyncConfigDraft get _draft => KoreaderSyncConfigDraft(
    serverUrl: _serverController.text.trim(),
    username: _usernameController.text.trim(),
    password: _passwordController.text,
    checksumMethod: _checksumMethod,
    allowInsecurePrivateHttp: _allowPrivateHttp,
  );

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _connectionError = null;
      _connectionVerified = false;
    });
    try {
      final sync = context.read<KoreaderSyncController>();
      final result = await sync.testConnection(_draft);
      setState(() {
        _connectionVerified = result.success;
        _connectionError = result.errorCode;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.success
                  ? context.l10n.koreaderTestSuccess
                  : koreaderErrorText(context, result.errorCode),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_connectionVerified) return;
    setState(() => _saving = true);
    try {
      final sync = context.read<KoreaderSyncController>();
      await sync.configure(_draft);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final sync = context.read<KoreaderSyncController>();
      await sync.register(_draft);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.koreaderRegisterSuccess)),
        );
        Navigator.of(context).pop();
      }
    } on KoreaderSyncFailure catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(koreaderErrorText(context, failure.code))),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.koreaderSyncSetUp)),
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
                  controller: _serverController,
                  decoration: InputDecoration(
                    labelText: l10n.koreaderServerUrl,
                    hintText: l10n.koreaderServerUrlHint,
                    prefixIcon: const Icon(Icons.dns_outlined),
                  ),
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  validator: (value) {
                    final uri = Uri.tryParse(value?.trim() ?? '');
                    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
                      return l10n.koreaderErrorInvalidConfiguration;
                    }
                    return null;
                  },
                  onChanged: (_) => _resetVerification(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    labelText: l10n.koreaderUsername,
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                  autocorrect: false,
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? l10n.koreaderErrorAuthentication
                      : null,
                  onChanged: (_) => _resetVerification(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: l10n.koreaderPassword,
                    helperText: l10n.koreaderPasswordHint,
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
                  validator: (value) => (value == null || value.isEmpty)
                      ? l10n.koreaderErrorAuthentication
                      : null,
                  onChanged: (_) => _resetVerification(),
                ),
                const SizedBox(height: 16),
                _ChecksumSelector(
                  method: _checksumMethod,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _checksumMethod = value;
                      _resetVerification();
                    });
                  },
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: Text(l10n.koreaderAllowPrivateHttp),
                  subtitle: Text(l10n.koreaderAllowPrivateHttpHint),
                  value: _allowPrivateHttp,
                  onChanged: (value) => setState(() {
                    _allowPrivateHttp = value;
                    _resetVerification();
                  }),
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_find_outlined),
                  label: Text(l10n.koreaderTestConnection),
                ),
                if (_connectionError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    koreaderErrorText(context, _connectionError),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: (_saving || !_connectionVerified) ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(l10n.koreaderSyncSetUp),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _saving ? null : _register,
                  icon: const Icon(Icons.person_add_outlined),
                  label: Text(l10n.koreaderRegisterAccount),
                ),
                Text(
                  l10n.koreaderRegisterDescription,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      l10n.koreaderFidelityNote,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _resetVerification() {
    if (_connectionVerified || _connectionError != null) {
      setState(() {
        _connectionVerified = false;
        _connectionError = null;
      });
    }
  }
}

class _ChecksumSelector extends StatelessWidget {
  const _ChecksumSelector({required this.method, required this.onChanged});

  final KoreaderChecksumMethod method;
  final ValueChanged<KoreaderChecksumMethod?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(l10n.koreaderChecksumMode),
        ),
        SegmentedButton<KoreaderChecksumMethod>(
          segments: [
            ButtonSegment(
              value: KoreaderChecksumMethod.partialMd5,
              label: Text(l10n.koreaderChecksumPartialMd5),
            ),
            ButtonSegment(
              value: KoreaderChecksumMethod.filename,
              label: Text(l10n.koreaderChecksumFilename),
            ),
          ],
          selected: {method},
          onSelectionChanged: (selection) {
            final value = selection.firstOrNull;
            if (value != null) onChanged(value);
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.koreaderChecksumHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
