import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../providers/providers.dart';
import '../services/local_llm.dart';
import '../widgets/ingestion_banner.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ready = ref.watch(modelReadyProvider);
    final stats = ref.watch(libraryStatsProvider).value;
    final busy = ref.watch(ingestionControllerProvider).isBusy;
    final controller = ref.read(ingestionControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(t('settings.title'))),
      body: Column(children: [
        const IngestionBanner(),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text(t('settings.model.title'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t('settings.model.body', {'name': defaultLocalModel.name, 'size': defaultLocalModel.approxSizeMb})),
            const SizedBox(height: 8),
            Text(ready ? t('settings.model.ready') : t('settings.model.missing'), style: theme.textTheme.bodySmall),
            if (!ready) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: busy ? null : controller.prepareModel,
                icon: const Icon(Icons.download),
                label: Text(t('settings.model.download')),
              ),
            ],
            const Divider(height: 40),
            Text(t('settings.pool.title'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t('settings.pool.body', {
              'shorts': stats?['pool_shorts'] ?? 0,
              'theorems': stats?['pool_theorems'] ?? 0,
            })),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy ? null : controller.buildTheoremPool,
              icon: const Icon(Icons.functions),
              label: Text(t('settings.pool.build')),
            ),
            if (stats != null) ...[
              const SizedBox(height: 8),
              Text(t('settings.stats', {'checked': stats['checked']!, 'accepted': stats['accepted']!}),
                  style: theme.textTheme.bodySmall),
            ],
            const Divider(height: 40),
            Text(t('settings.privacy.title'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t('settings.privacy.body'), style: theme.textTheme.bodySmall),
          ]),
        ),
      ]),
    );
  }
}
