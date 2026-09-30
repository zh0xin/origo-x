import 'package:flutter/material.dart';
import 'package:xxread/opds/models/opds_catalog.dart';
import 'package:xxread/opds/services/opds_registry.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';

import 'opds_browse_page.dart';
import 'opds_catalog_edit_page.dart';

/// OPDS 目录列表：已注册的目录、启用开关、进入浏览。
class OpdsCatalogListPage extends StatefulWidget {
  const OpdsCatalogListPage({super.key, this.registry});

  final OpdsRegistry? registry;

  @override
  State<OpdsCatalogListPage> createState() => _OpdsCatalogListPageState();
}

class _OpdsCatalogListPageState extends State<OpdsCatalogListPage> {
  late final OpdsRegistry _registry;
  List<OpdsCatalog> _catalogs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _registry = widget.registry ?? OpdsRegistry();
    _load();
  }

  Future<void> _load() async {
    final catalogs = await _registry.load();
    if (!mounted) return;
    setState(() {
      _catalogs = catalogs;
      _loading = false;
    });
  }

  Future<void> _openEditor({OpdsCatalog? existing}) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            OpdsCatalogEditPage(registry: _registry, existing: existing),
      ),
    );
    if (result == true) await _load();
  }

  Future<void> _confirmRemove(OpdsCatalog catalog) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.opdsCatalogRemoveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.opdsCatalogRemove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _registry.remove(catalog.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.opdsCatalogsTitle)),
      body: Container(
        decoration: BoxDecoration(
          gradient: PageStyleHelper.backgroundGradient(context),
        ),
        child: SafeArea(
          top: false,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _catalogs.isEmpty
              ? _EmptyState(onAdd: _openEditor)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    Text(
                      l10n.opdsCatalogsSubtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    for (final catalog in _catalogs)
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: Icon(
                            catalog.enabled
                                ? Icons.library_books_outlined
                                : Icons.library_books_outlined,
                            color: catalog.enabled
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          title: Text(catalog.title),
                          subtitle: Text(
                            catalog.url.toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: catalog.enabled,
                                onChanged: (value) async {
                                  await _registry.setEnabled(catalog, value);
                                  await _load();
                                },
                              ),
                              PopupMenuButton<String>(
                                onSelected: (value) {
                                  switch (value) {
                                    case 'edit':
                                      _openEditor(existing: catalog);
                                    case 'remove':
                                      _confirmRemove(catalog);
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text(l10n.opdsEditCatalog),
                                  ),
                                  PopupMenuItem(
                                    value: 'remove',
                                    child: Text(l10n.opdsCatalogRemove),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          onTap: catalog.enabled
                              ? () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => OpdsBrowsePage(
                                      catalog: catalog,
                                      registry: _registry,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openEditor,
        icon: const Icon(Icons.add),
        label: Text(l10n.opdsAddCatalog),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.travel_explore_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              context.l10n.opdsCatalogEmpty,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
