import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../providers/providers.dart';

/// Shows progress / results of a scoped-ingestion run.
class IngestionBanner extends ConsumerWidget {
  const IngestionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(ingestionControllerProvider);
    final r = s.report;
    final (String text, bool busy) = switch (s.status) {
      IngestionStatus.idle => ('', false),
      IngestionStatus.preparingModel => (
          s.modelProgress == null
              ? t('model.loading')
              : t('model.downloading', {'percent': (s.modelProgress! * 100).round()}),
          true
        ),
      IngestionStatus.running => (
          '${t('ingest.searching', {'concept': s.label})}\n'
              '${t('ingest.progress', {'checked': r?.checked ?? 0, 'accepted': r?.accepted ?? 0})}',
          true
        ),
      IngestionStatus.done => (t('ingest.done', {'accepted': r?.accepted ?? 0, 'checked': r?.checked ?? 0}), false),
      IngestionStatus.failed => (t('ingest.failed', {'message': s.message ?? ''}), false),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(children: [
          if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          if (busy) const SizedBox(width: 12),
          Expanded(child: Text(text)),
          if (busy && s.status == IngestionStatus.running)
            TextButton(
              onPressed: () => ref.read(ingestionControllerProvider.notifier).cancel(),
              child: Text(t('ingest.cancel')),
            ),
        ]),
      ),
    );
  }
}
