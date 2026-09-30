import 'package:flutter/material.dart';
import 'package:xxread/opds/models/opds_catalog.dart';
import 'package:xxread/opds/models/opds_feed.dart';
import 'package:xxread/opds/services/opds_client.dart';
import 'package:xxread/opds/services/opds_download_service.dart';
import 'package:xxread/opds/services/opds_registry.dart';
import 'package:xxread/pages/library/import_book/import_book_page.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';

/// 条目详情：书籍信息 + 可下载格式列表，下载后交给既有导入队列。
class OpdsEntryDetailPage extends StatefulWidget {
  const OpdsEntryDetailPage({
    super.key,
    required this.catalog,
    required this.registry,
    required this.entry,
  });

  final OpdsCatalog catalog;
  final OpdsRegistry registry;
  final OpdsEntry entry;

  @override
  State<OpdsEntryDetailPage> createState() => _OpdsEntryDetailPageState();
}

class _OpdsEntryDetailPageState extends State<OpdsEntryDetailPage> {
  late final OpdsDownloadService _downloadService;

  int? _selectedIndex;
  int _received = 0;
  int? _total;
  bool _downloading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 下载客户端必须与浏览页使用同一网络策略：浏览页按目录的
    // allowInsecurePrivateHttp 放行私网，若这里用默认严格策略，
    // 绑定在固定客户端上的 connectionFactory 会在实际建连时把内网地址判为
    // 非法而拒连——表现为“能浏览、下载失败”。
    _downloadService = OpdsDownloadService(
      client: OpdsClient(
        allowPrivateNetwork: widget.catalog.allowInsecurePrivateHttp,
      ),
    );
  }

  @override
  void dispose() {
    _downloadService.close();
    super.dispose();
  }

  void _select(int index) {
    setState(() {
      _selectedIndex = index;
      _received = 0;
      _total = null;
      _error = null;
    });
  }

  Future<void> _download() async {
    final index = _selectedIndex;
    final acquisitions = widget.entry.acquisitions;
    if (index == null || index >= acquisitions.length) return;

    setState(() {
      _downloading = true;
      _received = 0;
      _total = null;
      _error = null;
    });

    try {
      final password = await widget.registry.readPassword(widget.catalog);
      final source = await _downloadService.download(
        catalog: widget.catalog,
        catalogPassword: password,
        entry: widget.entry,
        link: acquisitions[index],
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImportBookPage(initialSources: [source]),
        ),
      );
    } on OpdsDownloadException catch (failure) {
      if (mounted) setState(() => _error = _messageFor(failure.code));
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.opdsDownloadFailed);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  String _messageFor(String code) {
    if (code == 'opds_unsupported_format') {
      return context.l10n.opdsUnsupportedFormat;
    }
    return context.l10n.opdsDownloadFailed;
  }

  String _formatLabel(OpdsLink link) {
    final format = OpdsDownloadService.resolveFormat(link);
    final type = link.type;
    if (type != null && type.isNotEmpty) return type;
    final extension = format.fileExtension();
    return extension.isEmpty ? link.relName : extension.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entry = widget.entry;
    final acquisitions = entry.acquisitions;
    final cover = entry.coverUrl ?? entry.thumbnailUrl;

    return Scaffold(
      appBar: AppBar(title: Text(entry.title)),
      body: Container(
        decoration: BoxDecoration(
          gradient: PageStyleHelper.backgroundGradient(context),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  children: [
                    if (cover != null)
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            cover.toString(),
                            width: 160,
                            height: 220,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                const SizedBox(width: 160, height: 220),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      entry.title,
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    if (entry.author.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry.author,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                    if (entry.summary.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(entry.summary),
                    ],
                    const SizedBox(height: 24),
                    Text(
                      l10n.opdsDownload,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    if (acquisitions.isEmpty)
                      Text(l10n.opdsNoAcquisition)
                    else
                      for (var i = 0; i < acquisitions.length; i++)
                        RadioListTile<int>(
                          title: Text(_formatLabel(acquisitions[i])),
                          value: i,
                          // ignore: deprecated_member_use
                          groupValue: _selectedIndex,
                          // ignore: deprecated_member_use
                          onChanged: (value) {
                            if (value != null) _select(value);
                          },
                        ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_downloading) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: LinearProgressIndicator(
                    value: _total != null && _total! > 0
                        ? (_received / _total!).clamp(0.0, 1.0)
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    l10n.opdsDownloading,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    onPressed:
                        _downloading ||
                            acquisitions.isEmpty ||
                            _selectedIndex == null
                        ? null
                        : _download,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(l10n.opdsDownload),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
