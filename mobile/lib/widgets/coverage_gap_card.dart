import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../models/feed.dart';

/// Shown inline when an active concept has zero videos. Gaps are never silent.
class CoverageGapCard extends StatelessWidget {
  const CoverageGapCard({super.key, required this.gap, this.onFind});

  final CoverageGap gap;

  /// Scoped ingestion for this concept (wired up in Phase C). Null = not yet available.
  final VoidCallback? onFind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('gap.title', {'concept': gap.concept}),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSecondaryContainer)),
            const SizedBox(height: 4),
            Text(t('gap.body'), style: TextStyle(color: scheme.onSecondaryContainer)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onFind,
              icon: const Icon(Icons.search),
              label: Text(t('gap.find')),
            ),
          ],
        ),
      ),
    );
  }
}
