import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../models/feed.dart';

/// Long-form recommendation card. The reason label is always visible.
class VideoCard extends StatelessWidget {
  const VideoCard({super.key, required this.card, required this.onTap, this.onConceptTap, this.onLongPress, this.badge});

  final FeedCard card;
  final VoidCallback onTap;

  /// Tapping the reason label opens the concept.
  final VoidCallback? onConceptTap;
  final VoidCallback? onLongPress;

  /// Small marker shown on the thumbnail (e.g. a golden-set label).
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minutes = card.durationSec == null ? null : (card.durationSec! / 60).round();
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (card.thumbnailUrl != null)
                    Image.network(
                      card.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                    )
                  else
                    ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                  if (badge != null) Positioned(left: 8, top: 8, child: badge!),
                  if (minutes != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(t('card.duration', {'min': minutes}),
                            style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: onConceptTap,
                    child: ReasonChip(fromMaterial: card.fromMaterial, label: card.reasonLabel),
                  ),
                  const SizedBox(height: 6),
                  Text(card.title, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (card.why != null && card.why!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(card.why!, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReasonChip extends StatelessWidget {
  const ReasonChip({super.key, required this.fromMaterial, required this.label});

  final bool fromMaterial;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMaterial = fromMaterial;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(isMaterial ? Icons.menu_book_outlined : Icons.functions,
            size: 16, color: isMaterial ? scheme.primary : scheme.tertiary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isMaterial ? scheme.primary : scheme.tertiary),
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
