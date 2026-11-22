import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../models/feed.dart';
import '../providers/providers.dart';
import '../widgets/coverage_gap_card.dart';
import '../widgets/ingestion_banner.dart';
import '../widgets/video_card.dart';
import 'concept_detail_screen.dart';
import 'player_screen.dart';
import 'settings_screen.dart';

/// Long-form feed: material-concept videos only. No fallback, no padding.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(longformFeedProvider);
    return Scaffold(
      appBar: AppBar(title: Text(t('home.title')), actions: [
        IconButton(
          tooltip: t('nav.settings'),
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
        ),
      ]),
      body: Column(children: [
        const IngestionBanner(),
        Expanded(child: RefreshIndicator(
        onRefresh: () => ref.refresh(longformFeedProvider.future),
        child: feed.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _Message(
            title: t('home.error'),
            action: FilledButton(onPressed: () => ref.invalidate(longformFeedProvider), child: Text(t('home.retry'))),
          ),
          data: (f) => f.needsUpload ? const _UploadEmptyState() : _FeedList(feed: f),
        ),
      )),
      ]),
    );
  }
}

class _FeedList extends ConsumerWidget {
  const _FeedList({required this.feed});
  final FeedResponse feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ingesting = ref.watch(ingestionControllerProvider).isBusy;
    void openConcept(String id) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ConceptDetailScreen(conceptId: id)));
    final children = <Widget>[
      for (final card in feed.items)
        VideoCard(
          card: card,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => PlayerScreen(videoId: card.videoId, title: card.title, reasonLabel: card.reasonLabel),
          )),
          onConceptTap: () => openConcept(card.conceptId),
        ),
      for (final gap in feed.coverageGaps)
        CoverageGapCard(
          gap: gap,
          onFind: ingesting ? null : () => ref.read(ingestionControllerProvider.notifier).findVideos(gap.conceptId),
          onOpen: () => openConcept(gap.conceptId),
        ),
    ];
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: children,
    );
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
          ref.read(tabProvider.notifier).select(2);
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
        if (icon != null) Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        if (body != null) ...[
          const SizedBox(height: 8),
          Text(body!, textAlign: TextAlign.center),
        ],
        if (action != null) ...[const SizedBox(height: 20), Center(child: action)],
      ],
    );
  }
}
