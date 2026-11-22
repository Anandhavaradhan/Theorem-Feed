import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../models/feed.dart';
import '../providers/providers.dart';
import '../services/search/search_service.dart';
import '../widgets/ingestion_banner.dart';
import 'concept_detail_screen.dart';
import 'player_screen.dart';

/// Search (§13.4): English input, grouped results, coverage-gap and
/// out-of-scope cards, concept chips that open the concept. Fully on the
/// device, so it works offline.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => ref.read(searchQueryProvider.notifier).set(text));
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchResultsProvider);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: false,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: t('search.hint'),
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _ctrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _ctrl.clear();
                      ref.read(searchQueryProvider.notifier).set('');
                      setState(() {});
                    },
                  ),
          ),
          onChanged: (v) {
            setState(() {});
            _onChanged(v);
          },
          onSubmitted: (v) => ref.read(searchQueryProvider.notifier).set(v),
        ),
      ),
      body: Column(children: [
        const IngestionBanner(),
        Expanded(
          child: results.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (r) => _Results(r: r),
          ),
        ),
      ]),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.r});
  final SearchResponse r;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notices = [
      if (r.materialInactive) t('search.material_inactive') else if (r.theoremOnly) t('search.theorem_only'),
    ];
    if (r.understanding.intent == QueryIntent.empty) {
      return ListView(padding: const EdgeInsets.all(24), children: [
        for (final n in notices) _Notice(text: n),
        Text(t('search.empty'), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
      ]);
    }
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      for (final n in notices) _Notice(text: n),
      if (r.outOfScope != null)
        Card(
          margin: const EdgeInsets.all(12),
          color: theme.colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.outOfScope!.message, style: theme.textTheme.titleSmall),
              if (!r.outOfScope!.alreadyTheoremOnly && !r.theoremOnly) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => ref.read(searchQueryProvider.notifier).theoremOnly(),
                  icon: const Icon(Icons.functions),
                  label: Text(t('search.out_of_scope_action')),
                ),
              ],
            ]),
          ),
        ),
      for (final g in r.groups) _Group(g: g),
    ]);
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(children: [
          const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );
}

class _Group extends ConsumerWidget {
  const _Group({required this.g});
  final SearchGroup g;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (String chip, Color color) = switch (g.kind) {
      GroupKind.material => (t('search.kind.material'), scheme.primary),
      GroupKind.theorem => (t('search.kind.theorem'), scheme.tertiary),
      _ => (t('search.kind.gap'), scheme.error),
    };
    final title = g.kind == GroupKind.prerequisiteGap ? t('search.prerequisite', {'name': g.conceptName}) : g.conceptName;
    final busy = ref.watch(ingestionControllerProvider).isBusy;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: InkWell(
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => ConceptDetailScreen(conceptId: g.conceptId))),
                child: Text(title.toUpperCase(), style: theme.textTheme.titleSmall?.copyWith(letterSpacing: 0.5)),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(10)),
              child: Text(chip, style: TextStyle(color: color, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(g.reasonLabel, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          if (g.isGap) ...[
            const SizedBox(height: 4),
            Row(children: [
              Text(t('search.no_videos')),
              const Spacer(),
              TextButton.icon(
                onPressed: busy ? null : () => ref.read(ingestionControllerProvider.notifier).findVideos(g.conceptId),
                icon: const Icon(Icons.search, size: 18),
                label: Text(t('search.find')),
              ),
            ]),
          ] else ...[
            Text(
              g.chapter == null
                  ? t('search.count', {'n': g.videos.length})
                  : t('search.count_chapter', {'n': g.videos.length, 'chapter': g.chapter!}),
              style: theme.textTheme.bodySmall,
            ),
            for (final v in g.videos) _VideoRow(card: v),
          ],
        ]),
      ),
    );
  }
}

class _VideoRow extends StatelessWidget {
  const _VideoRow({required this.card});
  final FeedCard card;

  @override
  Widget build(BuildContext context) {
    final minutes = card.durationSec == null ? null : (card.durationSec! / 60).round();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(card.isShort ? Icons.slow_motion_video : Icons.play_circle_outline),
      title: Text(card.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: minutes == null ? null : Text(t('card.duration', {'min': minutes})),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(videoId: card.videoId, title: card.title, reasonLabel: card.reasonLabel),
      )),
    );
  }
}
