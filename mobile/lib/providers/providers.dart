import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/feed.dart';
import '../models/resolved_video.dart';

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final longformFeedProvider = FutureProvider<FeedResponse>((ref) {
  return ref.watch(apiClientProvider).longformFeed();
});

/// No automatic retry: the player honours the server's `retry_after` itself.
final resolveProvider = FutureProvider.autoDispose.family<ResolvedVideo, String>(
  (ref, videoId) => ref.watch(apiClientProvider).resolve(videoId),
  retry: (_, _) => null,
);
