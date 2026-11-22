import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../models/feed.dart';
import '../models/resolved_video.dart';
import '../services/feed_service.dart';
import '../services/resolver.dart';

/// Opened in main() and injected with an override.
final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError('override in main()'));

final streamExtractorProvider = Provider<StreamExtractor>((ref) {
  final ex = YoutubeExplodeExtractor();
  ref.onDispose(ex.close);
  return ex;
});

final resolverProvider =
    Provider<Resolver>((ref) => Resolver(ref.watch(databaseProvider), ref.watch(streamExtractorProvider)));

final feedServiceProvider = Provider<FeedService>((ref) => FeedService(ref.watch(databaseProvider)));

final longformFeedProvider = FutureProvider<FeedResponse>((ref) async => ref.watch(feedServiceProvider).longform());

/// No automatic retry: the player honours the 30s retry contract itself.
final resolveProvider = FutureProvider.autoDispose.family<ResolvedVideo, String>(
  (ref, videoId) => ref.watch(resolverProvider).resolve(videoId),
  retry: (_, _) => null,
);
