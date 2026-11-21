import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../models/feed.dart';
import '../providers/providers.dart';
import '../widgets/coverage_gap_card.dart';
import '../widgets/video_card.dart';
import 'player_screen.dart';

/// Long-form feed: material-concept videos only. No fallback, no padding.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(longformFeedProvider);
    return Scaffold(
      appBar: AppBar(title: Text(t('home.title'))),
      body: RefreshIndicator(
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
    );
  }
}

class _FeedList extends StatelessWidget {
  const _FeedList({required this.feed});
  final FeedResponse feed;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      for (final card in feed.items)
        VideoCard(
          card: card,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => PlayerScreen(videoId: card.videoId, title: card.title, reasonLabel: card.reasonLabel),
          )),
        ),
      for (final gap in feed.coverageGaps) CoverageGapCard(gap: gap),
    ];
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: children,
    );
  }
}

class _UploadEmptyState extends StatelessWidget {
  const _UploadEmptyState();

  @override
  Widget build(BuildContext context) {
    return _Message(
      icon: Icons.upload_file,
      title: t('home.empty.title'),
      body: t('home.empty.body'),
      action: FilledButton.icon(
        // Material upload is Phase C.
        onPressed: () => ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t('home.empty.cta_soon')))),
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
