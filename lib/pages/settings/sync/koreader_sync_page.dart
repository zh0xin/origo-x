import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xxread/services/sync/koreader/koreader_models.dart';
import 'package:xxread/services/sync/koreader/koreader_sync_controller.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';

import 'koreader_setup_page.dart';
import 'koreader_sync_translator.dart';

/// KOReader 同步总览页：状态、自动同步、立即同步、进入配置。
class KoreaderSyncPage extends StatelessWidget {
  const KoreaderSyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<KoreaderSyncController>();
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.koreaderSyncTitle)),
      body: Container(
        decoration: BoxDecoration(
          gradient: PageStyleHelper.backgroundGradient(context),
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
            children: [
              _StatusCard(sync: sync),
              const SizedBox(height: 16),
              _BehaviorCard(sync: sync),
              const SizedBox(height: 16),
              _ConnectionCard(sync: sync),
              const SizedBox(height: 16),
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
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.sync});
  final KoreaderSyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final statusText = switch (sync.status) {
      KoreaderSyncStatus.unconfigured => l10n.koreaderSyncNotConfigured,
      KoreaderSyncStatus.idle => l10n.koreaderSyncConnected,
      KoreaderSyncStatus.testing => l10n.koreaderSyncSyncing,
      KoreaderSyncStatus.syncing => l10n.koreaderSyncSyncing,
      KoreaderSyncStatus.success => l10n.koreaderSyncConnected,
      KoreaderSyncStatus.partialFailure => l10n.koreaderSyncFailed,
      KoreaderSyncStatus.failed => l10n.koreaderSyncFailed,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  sync.isConfigured
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(statusText)),
                if (sync.busy)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (sync.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                koreaderErrorText(context, sync.lastError),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (sync.lastResult != null) ...[
              const SizedBox(height: 8),
              Text(
                l10n.koreaderSyncPushedPulled(
                  sync.lastResult!.pushed,
                  sync.lastResult!.pulled,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BehaviorCard extends StatelessWidget {
  const _BehaviorCard({required this.sync});
  final KoreaderSyncController sync;

  @override
  Widget build(BuildContext context) {
    if (!sync.isConfigured) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: Text(l10n.koreaderSyncOnOpen),
            value: sync.configuration?.syncOnOpen ?? true,
            onChanged: (value) => sync.setSyncOnOpen(value),
          ),
          SwitchListTile(
            title: Text(l10n.koreaderSyncOnSave),
            value: sync.configuration?.syncOnSave ?? true,
            onChanged: (value) => sync.setSyncOnSave(value),
          ),
          SwitchListTile(
            title: Text(l10n.koreaderPreferLocalFirstSync),
            value: sync.configuration?.preferLocalOnFirstSync ?? false,
            onChanged: (value) => sync.setPreferLocalOnFirstSync(value),
          ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.sync});
  final KoreaderSyncController sync;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Card(
      child: Column(
        children: [
          if (sync.isConfigured)
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(sync.serverUrl ?? ''),
              subtitle: Text(sync.username ?? ''),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const KoreaderSetupPage(),
                ),
              ),
            )
          else
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(l10n.koreaderSyncSetUp),
              subtitle: Text(l10n.koreaderSyncConfigureSubtitle),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const KoreaderSetupPage(),
                ),
              ),
            ),
          if (sync.isConfigured) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.sync_outlined),
              title: Text(l10n.koreaderSyncNow),
              enabled: !sync.busy,
              onTap: () => sync.syncNow(),
            ),
          ],
        ],
      ),
    );
  }
}
