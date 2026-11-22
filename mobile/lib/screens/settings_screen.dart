import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../providers/providers.dart';
import '../services/local_llm.dart';
import '../services/relevance/evaluation.dart';
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
            const _RelevanceCheck(),
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

class _RelevanceCheck extends ConsumerWidget {
  const _RelevanceCheck();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final progress = ref.watch(goldenProgressProvider).value;
    final s = ref.watch(evaluationControllerProvider);
    final report = s.report;
    String pct(double? x) => x == null ? '–' : x.toStringAsFixed(2);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t('eval.title'), style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(t('eval.body', {'concepts': goldenConceptsTarget, 'videos': goldenVideosPerConcept})),
      if (progress != null) ...[
        const SizedBox(height: 8),
        Text(t('eval.progress', {'concepts': progress.concepts, 'target': goldenConceptsTarget, 'videos': progress.videos}),
            style: theme.textTheme.bodySmall),
      ],
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: s.status == EvalStatus.running || (progress?.concepts ?? 0) == 0
            ? null
            : () => ref.read(evaluationControllerProvider.notifier).run(),
        icon: const Icon(Icons.fact_check),
        label: Text(t('eval.run')),
      ),
      if ((progress?.concepts ?? 0) == 0) ...[
        const SizedBox(height: 4),
        Text(t('eval.none'), style: theme.textTheme.bodySmall),
      ],
      if (s.status == EvalStatus.running) ...[
        const SizedBox(height: 8),
        Text(t('eval.running', {'done': s.done, 'total': s.total})),
      ],
      if (s.status == EvalStatus.failed) Text(t('eval.failed', {'message': s.message ?? ''})),
      if (report != null) ...[
        const SizedBox(height: 8),
        Text(t('eval.result', {'precision': pct(report.precisionAt10), 'bad': pct(report.badRateAt10)}),
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        Text(report.passes ? t('eval.pass') : t('eval.fail'),
            style: TextStyle(color: report.passes ? Colors.green : theme.colorScheme.error)),
        for (final c in report.concepts)
          Text(t('eval.concept', {'name': c.name, 'good': c.goodShown, 'bad': c.badShown, 'shown': c.shown}),
              style: theme.textTheme.bodySmall),
      ],
    ]);
  }
}
