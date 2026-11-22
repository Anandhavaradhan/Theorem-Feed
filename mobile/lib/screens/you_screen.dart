import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../core/theme.dart';
import '../models/feed.dart';
import '../providers/providers.dart';
import '../widgets/thumbnail.dart';
import '../widgets/video_card.dart';
import 'player_screen.dart';
import 'settings_screen.dart';

/// "You": history and saved videos as horizontal shelves, plus settings.
class YouScreen extends ConsumerWidget {
  const YouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider).value ?? const <FeedCard>[];
    final saved = ref.watch(savedProvider).value ?? const <FeedCard>[];
    final now = ref.watch(studyingNowProvider).value;
    final meta = Theme.of(context).colorScheme.onSurfaceVariant;
    void open(FeedCard c) => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(videoId: c.videoId, title: c.title, reasonLabel: c.reasonLabel),
        ));
    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(
          tooltip: t('nav.settings'),
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
        ),
      ]),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(children: [
            const ConceptAvatar('You', radius: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('nav.you'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                if (now != null && now.materials > 0)
                  Text(t('material.summary', {'materials': now.materials, 'concepts': now.concepts}),
                      style: TextStyle(color: meta)),
              ]),
            ),
          ]),
        ),
        _Shelf(title: t('you.history'), items: history, empty: t('you.history_empty'), onOpen: open),
        _Shelf(title: t('you.saved'), items: saved, empty: t('you.saved_empty'), onOpen: open),
        const Divider(height: 24),
        ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: Text(t('nav.material')),
          onTap: () => ref.read(tabProvider.notifier).select(materialTab),
        ),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: Text(t('nav.settings')),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
        ),
      ]),
    );
  }
}

class _Shelf extends StatelessWidget {
  const _Shelf({required this.title, required this.items, required this.empty, required this.onOpen});
  final String title;
  final List<FeedCard> items;
  final String empty;
  final void Function(FeedCard) onOpen;

  @override
  Widget build(BuildContext context) {
    final meta = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      ),
      if (items.isEmpty)
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text(empty, style: TextStyle(color: meta)))
      else
        SizedBox(
          height: 170,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final c = items[i];
              return InkWell(
                onTap: () => onOpen(c),
                child: SizedBox(
                  width: 160,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Stack(fit: StackFit.expand, children: [
                          Thumbnail(c.thumbnailUrl),
                          if (c.durationSec != null)
                            Positioned(right: 4, bottom: 4, child: DurationBadge(seconds: c.durationSec!)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    if (c.conceptName.isNotEmpty)
                      Text(c.conceptName, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: meta)),
                  ]),
                ),
              );
            },
          ),
        ),
    ]);
  }
}
