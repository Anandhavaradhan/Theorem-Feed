import 'package:material_ui/material_ui.dart';

import '../core/i18n.dart';
import '../core/theme.dart';
import '../models/feed.dart';
import '../screens/shorts_screen.dart';
import 'thumbnail.dart';

/// A row of vertical short thumbnails, as on YouTube (Home and search results); tapping
/// one opens the full-screen Shorts player, where you swipe through the rest.
class ShortsShelf extends StatelessWidget {
  const ShortsShelf({super.key, required this.shorts});
  final List<FeedCard> shorts;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(children: [
            const Icon(Icons.slow_motion_video, color: AppColors.accent),
            const SizedBox(width: 8),
            Text(t('search.shorts'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ]),
        ),
        SizedBox(
          height: 260,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: shorts.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final v = shorts[i];
              return GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => ShortsViewer(items: shorts, initialIndex: i),
                )),
                child: SizedBox(
                  width: 146,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded( // the thumbnail takes the height the title leaves
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(width: double.infinity, child: Thumbnail(v.thumbnailUrl)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                  ]),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

