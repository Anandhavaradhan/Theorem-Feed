import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../core/theme.dart';
import '../models/feed.dart';
import '../providers/providers.dart';
import '../widgets/coverage_gap_card.dart';
import '../widgets/ingestion_banner.dart';
import '../widgets/video_card.dart';
import 'concept_detail_screen.dart';
import 'player_screen.dart';
import 'search_screen.dart';

/// Long-form feed: material-concept videos only. No fallback, no padding.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(longformFeedProvider);
    return Scaffold(
      appBar: const BrandAppBar(),
      body: Column(children: [
        const IngestionBanner(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.refresh(longformFeedProvider.future),
            child: feed.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _Message(
                title: t('home.error'),
                action: FilledButton(onPressed: () => ref.invalidate(longformFeedProvider), child: Text(t('home.retry'))),
              ),
              data: (f) => f.needsUpload ? const _UploadEmptyState() : _FeedList(feed: f),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The top bar: app mark + name on the left, search on the right.
class BrandAppBar extends StatelessWidget implements PreferredSizeWidget {
  const BrandAppBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 12,
      title: Row(mainAxisSize: MainAxisSize.min, children: [
        const AppMark(size: 22),
        const SizedBox(width: 6),
        Text(t('app.title'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.6)),
      ]),
      actions: [
        IconButton(
          tooltip: t('nav.search'),
          icon: const Icon(Icons.search, size: 26),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _Chips extends ConsumerWidget {
  const _Chips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final concepts = ref.watch(activeConceptsProvider).value ?? const [];
    final selected = ref.watch(homeFilterProvider);
    if (concepts.isEmpty) return const SizedBox.shrink();
    Widget chip(String label, String? id) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label, style: TextStyle(color: selected == id ? Theme.of(context).colorScheme.surface : null)),
            selected: selected == id,
            onSelected: (_) => ref.read(homeFilterProvider.notifier).select(id),
          ),
        );
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [chip(t('home.all'), null), for (final c in concepts) chip(c.name, c.id)],
      ),
    );
  }
}

class _FeedList extends ConsumerWidget {
  const _FeedList({required this.feed});
  final FeedResponse feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ingesting = ref.watch(ingestionControllerProvider).isBusy;
    final filter = ref.watch(homeFilterProvider);
    void openConcept(String id) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ConceptDetailScreen(conceptId: id)));
    final items = [for (final c in feed.items) if (filter == null || c.conceptId == filter) c];
    final gaps = [for (final g in feed.coverageGaps) if (filter == null || g.conceptId == filter) g];
    final tiles = <Widget>[
      for (final card in items)
        VideoCard(
          card: card,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => PlayerScreen(videoId: card.videoId, title: card.title, reasonLabel: card.reasonLabel),
          )),
          onConceptTap: () => openConcept(card.conceptId),
          menu: {
            t('menu.save'): () => ref.read(conceptServiceProvider).toggleSaved(card.videoId),
            t('menu.open_concept'): () => openConcept(card.conceptId),
          },
        ),
      for (final gap in gaps)
        CoverageGapCard(
          gap: gap,
          onFind: ingesting ? null : () => ref.read(ingestionControllerProvider.notifier).findVideos(gap.conceptId),
          onOpen: () => openConcept(gap.conceptId),
        ),
    ];
    return LayoutBuilder(builder: (context, box) {
      // Phone: one column. Tablet: a grid, as video apps do on large screens.
      final cols = box.maxWidth >= 1100 ? 3 : box.maxWidth >= 700 ? 2 : 1;
      final rows = <Widget>[
        for (var i = 0; i < tiles.length; i += cols)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: cols > 1 ? 8 : 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var j = i; j < i + cols; j++) Expanded(child: j < tiles.length ? tiles[j] : const SizedBox()),
            ]),
          ),
      ];
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [const _Chips(), const SizedBox(height: 4), ...rows],
      );
    });
  }
}

class _UploadEmptyState extends ConsumerWidget {
  const _UploadEmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Message(
      icon: Icons.upload_file,
      title: t('home.empty.title'),
      body: t('home.empty.body'),
      action: FilledButton.icon(
        onPressed: () {
          ref.read(tabProvider.notifier).select(materialTab);
          ref.read(materialControllerProvider.notifier).pickAndUpload();
        },
        icon: const Icon(Icons.upload),
        label: Text(t('home.empty.cta')),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, this.body, this.icon, this.action});
  final String title;
  final String? body;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    // Scrollable so pull-to-refresh works on empty/error states too.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
      children: [
        if (icon != null) Icon(icon, size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        if (body != null) ...[
          const SizedBox(height: 8),
          Text(body!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
        if (action != null) ...[const SizedBox(height: 24), Center(child: action)],
      ],
    );
  }
}
