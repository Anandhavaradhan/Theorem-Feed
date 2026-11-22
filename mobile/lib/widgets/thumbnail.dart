import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

/// Video thumbnails, cached on disk so feeds look right offline and scrolling
/// doesn't re-download them.
class Thumbnail extends StatelessWidget {
  const Thumbnail(this.url, {super.key, this.fit = BoxFit.cover});
  final String? url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest);
    final u = url;
    if (u == null) return placeholder;
    return CachedNetworkImage(
      imageUrl: u,
      fit: fit,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }

  /// Warm the cache for an upcoming thumbnail.
  static Future<void> precache(BuildContext context, String? url) async {
    if (url == null) return;
    try {
      await precacheImage(CachedNetworkImageProvider(url), context);
    } catch (_) {}
  }
}
