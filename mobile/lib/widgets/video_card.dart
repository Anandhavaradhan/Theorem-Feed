import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../models/feed.dart';
import 'thumbnail.dart';

/// A home-feed item, as on YouTube: 16:9 thumbnail with a duration badge, then
/// the channel's round avatar, a two-line title and the channel name. Which
/// concept of your notes it belongs to stays out of the feed (the watch page
/// and the ⋮ menu show it).
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.card,
    required this.onTap,
    this.onConceptTap,
    this.onLongPress,
    this.badge,
    this.menu,
  });

  final FeedCard card;
  final VoidCallback onTap;

  /// Tapping the avatar or the reason label opens the concept.
  final VoidCallback? onConceptTap;
  final VoidCallback? onLongPress;

  /// Small marker shown on the thumbnail (e.g. a golden-set label).
  final Widget? badge;

  /// Items for the ⋮ menu (label → action).
  final Map<String, VoidCallback>? menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = theme.colorScheme.onSurfaceVariant;
    return LayoutBuilder(builder: (context, box) {
      // Phones: edge-to-edge thumbnails. Wider layouts (tablet grid): rounded.
      final inset = box.maxWidth >= 500;
      final radius = inset ? BorderRadius.circular(12) : BorderRadius.zero;
      return InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.fromLTRB(inset ? 8 : 0, 0, inset ? 8 : 0, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: radius,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(fit: StackFit.expand, children: [
                  Thumbnail(card.thumbnailUrl),
                  if (badge != null) Positioned(left: 8, top: 8, child: badge!),
                  if (card.durationSec != null)
                    Positioned(right: 8, bottom: 8, child: DurationBadge(seconds: card.durationSec!)),
                ]),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(inset ? 0 : 12, 12, 0, 0),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                GestureDetector(onTap: onConceptTap, child: ConceptAvatar(card.channel ?? card.title)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(card.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.25)),
                    if (card.channel != null && card.channel!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(card.channel!,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: meta)),
                    ],
                  ]),
                ),
                if (menu != null && menu!.isNotEmpty)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20),
                    padding: EdgeInsets.zero,
                    onSelected: (k) => menu![k]?.call(),
                    itemBuilder: (_) => [for (final k in menu!.keys) PopupMenuItem(value: k, child: Text(k))],
                  )
                else
                  const SizedBox(width: 12),
              ]),
            ),
          ]),
        ),
      );
    });
  }
}

class DurationBadge extends StatelessWidget {
  const DurationBadge({super.key, required this.seconds});
  final int seconds;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(4)),
        child: Text(formatDuration(seconds),
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
      );
}

/// Compact row for "Up next", search and history: thumbnail left, text right.
class VideoRow extends StatelessWidget {
  const VideoRow({super.key, required this.card, required this.onTap, this.subtitle});
  final FeedCard card;
  final VoidCallback onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final meta = Theme.of(context).colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 160,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(fit: StackFit.expand, children: [
                  Thumbnail(card.thumbnailUrl),
                  if (card.durationSec != null)
                    Positioned(right: 4, bottom: 4, child: DurationBadge(seconds: card.durationSec!)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(card.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(subtitle ?? card.reasonLabel,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: meta)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Kept for callers that only need the reason text styled consistently.
class ReasonChip extends StatelessWidget {
  const ReasonChip({super.key, required this.fromMaterial, required this.label});
  final bool fromMaterial;
  final String label;

  @override
  Widget build(BuildContext context) =>
      Text(label, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant));
}
