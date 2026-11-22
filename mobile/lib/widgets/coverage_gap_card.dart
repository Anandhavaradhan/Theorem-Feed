import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../models/feed.dart';

/// Shown inline when an active concept has zero videos. Gaps are never silent.
class CoverageGapCard extends StatelessWidget {
  const CoverageGapCard({super.key, required this.gap, this.onFind, this.onOpen});

  final CoverageGap gap;

  /// Runs scoped ingestion (Path A) for this concept. Null while a run is in progress.
  final VoidCallback? onFind;

  /// Opens the concept detail.
  final VoidCallback? onOpen;

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
            InkWell(
              onTap: onOpen,
              child: Text(t('gap.title', {'concept': gap.concept}),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSecondaryContainer)),
            ),
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
