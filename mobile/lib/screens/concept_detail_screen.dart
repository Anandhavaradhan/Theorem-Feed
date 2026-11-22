import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../providers/providers.dart';
import '../services/concept_service.dart';
import '../widgets/ingestion_banner.dart';
import '../widgets/video_card.dart';
import 'player_screen.dart';

/// Concept detail (§13.6): statement, LaTeX, prerequisite chain, videos, and
/// "No videos yet — find some" (scoped ingestion, only for in-scope concepts).
class ConceptDetailScreen extends ConsumerWidget {
  const ConceptDetailScreen({super.key, required this.conceptId});
  final String conceptId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(conceptDetailProvider(conceptId));
    return Scaffold(
      appBar: AppBar(title: Text(detail.value?.name ?? '')),
      body: Column(children: [
        const IngestionBanner(),
        Expanded(
          child: detail.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (d) => d == null ? Center(child: Text(t('concept.not_found'))) : _Body(d: d),
          ),
        ),
      ]),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.d});
  final ConceptDetail d;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ingesting = ref.watch(ingestionControllerProvider).isBusy;
    return ListView(padding: const EdgeInsets.symmetric(vertical: 12), children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(spacing: 8, runSpacing: 4, children: [
          Chip(label: Text(d.type)),
          Chip(label: Text(d.subject)),
          if (d.difficulty != null) Chip(label: Text(d.difficulty!)),
          if (d.inMaterial) Chip(avatar: const Icon(Icons.menu_book, size: 16), label: Text(t('concept.badge.material'))),
          if (d.inTheoremPool) Chip(avatar: const Icon(Icons.functions, size: 16), label: Text(t('concept.badge.theorem'))),
        ]),
      ),
      _Section(title: d.inMaterial ? t('concept.from_material') : t('concept.statement'), children: [
        Text(d.statement, style: theme.textTheme.bodyLarge),
        if (d.chapter != null || d.section != null) ...[
          const SizedBox(height: 6),
          Text(
            [
              if (d.chapter != null) t('concept.chapter', {'chapter': d.chapter!}),
              if (d.section != null) t('concept.section', {'section': d.section!}),
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (d.latex != null) ...[
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Math.tex(
              d.latex!,
              textStyle: theme.textTheme.titleLarge,
              onErrorFallback: (_) => Text(d.latex!, style: const TextStyle(fontFamily: 'monospace')),
            ),
          ),
        ],
      ]),
      _Section(title: t('concept.prerequisites'), children: [
        if (d.prerequisites.isEmpty) Text(t('concept.no_prerequisites')),
        for (final p in d.prerequisites)
          InkWell(
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => ConceptDetailScreen(conceptId: p.id))),
            child: Padding(
              padding: EdgeInsets.only(left: 16.0 * (p.depth - 1), top: 6, bottom: 6),
              child: Row(children: [
                Icon(p.depth == 1 ? Icons.subdirectory_arrow_right : Icons.more_horiz, size: 18),
                const SizedBox(width: 6),
                Flexible(child: Text(p.name, style: TextStyle(fontWeight: p.depth == 1 ? FontWeight.w600 : null))),
                if (p.inMaterial) ...[
                  const SizedBox(width: 6),
                  Text('· ${t('concept.in_material')}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                ],
              ]),
            ),
          ),
      ]),
      _Section(title: t('concept.videos'), children: [
        if (d.videos.isEmpty) ...[
          Text(t('concept.no_videos'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (d.canFindVideos)
            FilledButton.icon(
              onPressed: ingesting ? null : () => ref.read(ingestionControllerProvider.notifier).findVideos(d.id),
              icon: const Icon(Icons.search),
              label: Text(t('concept.find')),
            )
          else
            Text(t('concept.out_of_scope'), style: theme.textTheme.bodySmall),
        ],
      ]),
      for (final v in d.videos)
        VideoCard(
          card: v,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => PlayerScreen(videoId: v.videoId, title: v.title, reasonLabel: v.reasonLabel),
          )),
        ),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }
}
