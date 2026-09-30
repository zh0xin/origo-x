import 'package:flutter/material.dart';
import 'package:xxread/opds/models/opds_catalog.dart';
import 'package:xxread/opds/models/opds_feed.dart';
import 'package:xxread/opds/services/opds_client.dart';
import 'package:xxread/opds/services/opds_parser.dart';
import 'package:xxread/opds/services/opds_registry.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';

import 'opds_entry_detail_page.dart';

/// 浏览一个 OPDS 目录：导航 feed 与获取 feed 共用此页，靠 `rel` 关系翻页与返回。
class OpdsBrowsePage extends StatefulWidget {
  const OpdsBrowsePage({
    super.key,
    required this.catalog,
    required this.registry,
  });

  final OpdsCatalog catalog;
  final OpdsRegistry registry;

  @override
  State<OpdsBrowsePage> createState() => _OpdsBrowsePageState();
}

class _OpdsBrowsePageState extends State<OpdsBrowsePage> {
  /// 已访问的 feed 栈，用于面包屑与系统返回。
  final List<OpdsFeed> _history = <OpdsFeed>[];

  String? _password;
  bool _loading = true;
  String? _error;
  OpdsClient? _client;

  OpdsFeed? get _current => _history.isEmpty ? null : _history.last;

  @override
  void initState() {
    super.initState();
    _client = OpdsClient(
      allowPrivateNetwork: widget.catalog.allowInsecurePrivateHttp,
    );
    _load(widget.catalog.url, push: true);
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  Future<void> _load(Uri url, {required bool push}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _password ??= await widget.registry.readPassword(widget.catalog);
      final bytes = await _client!.fetchFeedBytes(
        url,
        username: widget.catalog.requiresAuth
            ? widget.catalog.authUsername
            : null,
        password: _password,
        allowInsecurePrivateHttp: widget.catalog.allowInsecurePrivateHttp,
      );
      final feed = OpdsParser.parse(bytes, baseUrl: url);
      if (!mounted) return;
      setState(() {
        if (push) {
          _history.add(feed);
        } else if (_history.isNotEmpty) {
          _history[_history.length - 1] = feed;
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // 带出底层异常原文，便于定位连接/解析/TLS 等具体失败原因。
        _error = '${context.l10n.opdsLoadFailed}\n\n$error';
        _loading = false;
      });
    }
  }

  void _goUp() {
    if (_history.length <= 1) return;
    setState(() => _history.removeLast());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final feed = _current;
    return PopScope(
      canPop: _history.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(feed?.title ?? widget.catalog.title),
          leading: _history.length > 1
              ? IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: _goUp,
                )
              : null,
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: PageStyleHelper.backgroundGradient(context),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                if (_history.length > 1) _Breadcrumb(history: _history),
                Expanded(child: _buildBody(l10n, feed)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(dynamic l10n, OpdsFeed? feed) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorState(
        message: _error!,
        onRetry: () =>
            _load(_current?.selfUrl ?? widget.catalog.url, push: false),
      );
    }
    if (feed == null) return const SizedBox.shrink();
    if (feed.entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l10n.opdsCatalogEmpty,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: feed.entries.length,
      itemBuilder: (context, index) => _EntryTile(
        entry: feed.entries[index],
        onTap: (entry) {
          if (entry.isNavigation) {
            final target = _firstLink(entry);
            if (target != null) _load(target, push: true);
          } else {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => OpdsEntryDetailPage(
                  catalog: widget.catalog,
                  registry: widget.registry,
                  entry: entry,
                ),
              ),
            );
          }
        },
      ),
    );
  }

  Uri? _firstLink(OpdsEntry entry) {
    for (final link in entry.links) {
      if (link.relName == 'subsection' || link.relName == 'navigation') {
        return link.href;
      }
    }
    // 回退到任意非获取、非封面的链接（多数目录用 alternate/related 指子 feed）。
    for (final link in entry.links) {
      if (!link.isAcquisition && !link.isCover && !link.isThumbnail) {
        return link.href;
      }
    }
    return null;
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.history});
  final List<OpdsFeed> history;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (var i = 0; i < history.length; i++) ...[
            if (i > 0) const Icon(Icons.chevron_right_rounded, size: 16),
            Text(
              history[i].title,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: i == history.length - 1
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onTap});

  final OpdsEntry entry;
  final ValueChanged<OpdsEntry> onTap;

  @override
  Widget build(BuildContext context) {
    final thumbnail = entry.thumbnailUrl ?? entry.coverUrl;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: thumbnail != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  thumbnail.toString(),
                  width: 44,
                  height: 60,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox(width: 44, height: 60),
                ),
              )
            : SizedBox(
                width: 44,
                height: 60,
                child: Icon(
                  entry.isNavigation
                      ? Icons.folder_outlined
                      : Icons.menu_book_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
        title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: entry.author.isEmpty
            ? null
            : Text(entry.author, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Icon(
          entry.isNavigation
              ? Icons.chevron_right_rounded
              : Icons.download_outlined,
        ),
        onTap: () => onTap(entry),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 48),
          const SizedBox(height: 12),
          Text(message),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(context.l10n.opdsRetry),
          ),
        ],
      ),
    );
  }
}
