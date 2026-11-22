import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../providers/providers.dart';
import '../widgets/ingestion_banner.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _key = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final value = _key.text.trim();
    if (value.isEmpty) return;
    await ref.read(apiKeyStoreProvider).write(value);
    _key.clear();
    ref.invalidate(hasApiKeyProvider);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('settings.key.saved'))));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasKey = ref.watch(hasApiKeyProvider).value ?? false;
    final stats = ref.watch(libraryStatsProvider).value;
    final ingesting = ref.watch(ingestionControllerProvider).isRunning;

    return Scaffold(
      appBar: AppBar(title: Text(t('settings.title'))),
      body: Column(children: [
        const IngestionBanner(),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text(t('settings.key.title'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t('settings.key.body'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(hasKey ? t('settings.key.present') : t('settings.key.missing')),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(border: const OutlineInputBorder(), hintText: t('settings.key.hint')),
              onSubmitted: (_) => _saveKey(),
            ),
            const SizedBox(height: 8),
            Row(children: [
              FilledButton(onPressed: _saveKey, child: Text(t('settings.key.save'))),
              const SizedBox(width: 8),
              if (hasKey)
                TextButton(
                  onPressed: () async {
                    await ref.read(apiKeyStoreProvider).clear();
                    ref.invalidate(hasApiKeyProvider);
                  },
                  child: Text(t('settings.key.clear')),
                ),
            ]),
            const Divider(height: 40),
            Text(t('settings.pool.title'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t('settings.pool.body', {
              'shorts': stats?['pool_shorts'] ?? 0,
              'theorems': stats?['pool_theorems'] ?? 0,
            })),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: ingesting || !hasKey
                  ? null
                  : () => ref.read(ingestionControllerProvider.notifier).buildTheoremPool(),
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
