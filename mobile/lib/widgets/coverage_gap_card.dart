import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../core/theme.dart';
import '../models/feed.dart';

/// An active concept with no videos, shown in the feed like a video item with
/// an empty thumbnail. Coverage gaps are never silent (#12).
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
    return LayoutBuilder(builder: (context, box) {
      final inset = box.maxWidth >= 500;
      return Padding(
        padding: EdgeInsets.fromLTRB(inset ? 8 : 0, 0, inset ? 8 : 0, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: inset ? BorderRadius.circular(12) : BorderRadius.zero,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: InkWell(
                onTap: onOpen,
                child: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.video_library_outlined, size: 40, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: onFind,
                        icon: const Icon(Icons.search, size: 18),
                        label: Text(t('gap.find')),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(inset ? 0 : 12, 12, 12, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GestureDetector(onTap: onOpen, child: ConceptAvatar(gap.concept)),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: onOpen,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t('gap.title', {'concept': gap.concept}),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 4),
                    Text(t('gap.body'), style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      );
    });
  }
}
