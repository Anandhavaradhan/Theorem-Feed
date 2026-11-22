import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../models/feed.dart';
import '../models/resolved_video.dart';
import '../services/api_key_store.dart';
import '../services/claude_client.dart';
import '../services/llm.dart';
import '../services/concept_service.dart';
import '../services/feed_service.dart';
import '../services/gates.dart';
import '../services/ingestion_service.dart';
import '../services/resolver.dart';
import '../services/youtube_source.dart';

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
final conceptServiceProvider = Provider<ConceptService>((ref) => ConceptService(ref.watch(databaseProvider)));

final longformFeedProvider = FutureProvider<FeedResponse>((ref) async => ref.watch(feedServiceProvider).longform());
final shortsFeedProvider = FutureProvider<FeedResponse>((ref) async => ref.watch(feedServiceProvider).shorts(limit: 100));

final conceptDetailProvider = FutureProvider.autoDispose.family<ConceptDetail?, String>(
  (ref, id) async => ref.watch(conceptServiceProvider).detail(id),
);

final libraryStatsProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) async => ref.watch(conceptServiceProvider).libraryStats());

/// No automatic retry: the player honours the 30s retry contract itself.
final resolveProvider = FutureProvider.autoDispose.family<ResolvedVideo, String>(
  (ref, videoId) => ref.watch(resolverProvider).resolve(videoId),
  retry: (_, _) => null,
);

// --- Claude API key + ingestion ----------------------------------------------

final apiKeyStoreProvider = Provider<ApiKeyStore>((ref) => SecureApiKeyStore());
final hasApiKeyProvider = FutureProvider<bool>((ref) async => (await ref.watch(apiKeyStoreProvider).read()) != null);

final videoSourceProvider = Provider<VideoSource>((ref) {
  final s = YoutubeExplodeSource();
  ref.onDispose(s.close);
  return s;
});

final speechProbeProvider = Provider<SpeechLanguageProbe?>((ref) => WhisperSpeechProbe());

/// Builds a JSON model for a key; overridable in tests.
final jsonModelFactoryProvider = Provider<JsonModel Function(String apiKey)>((ref) => (key) => ClaudeClient(apiKey: key));

enum IngestionStatus { idle, running, done, needsApiKey, badApiKey, failed }

class IngestionState {
  const IngestionState({this.status = IngestionStatus.idle, this.label = '', this.report, this.message});
  final IngestionStatus status;
  final String label; // concept currently being searched
  final IngestReport? report;
  final String? message;
  bool get isRunning => status == IngestionStatus.running;
}

class IngestionController extends Notifier<IngestionState> {
  bool _cancel = false;

  @override
  IngestionState build() => const IngestionState();

  Future<IngestionService?> _service() async {
    final key = await ref.read(apiKeyStoreProvider).read();
    if (key == null || key.isEmpty) {
      state = const IngestionState(status: IngestionStatus.needsApiKey);
      return null;
    }
    return IngestionService(
      db: ref.read(databaseProvider),
      source: ref.read(videoSourceProvider),
      model: ref.read(jsonModelFactoryProvider)(key),
      speechProbe: ref.read(speechProbeProvider),
    );
  }

  Future<void> _run(Future<IngestReport> Function(IngestionService s, IngestProgress p) job) async {
    if (state.isRunning) return;
    final svc = await _service();
    if (svc == null) return;
    _cancel = false;
    state = const IngestionState(status: IngestionStatus.running);
    try {
      final report = await job(svc, (label, r) {
        state = IngestionState(status: IngestionStatus.running, label: label, report: r);
      });
      state = IngestionState(status: IngestionStatus.done, report: report);
    } on ModelApiError catch (e) {
      state = IngestionState(
        status: e.isAuth ? IngestionStatus.badApiKey : IngestionStatus.failed,
        report: state.report,
        message: e.message,
      );
    } catch (e) {
      state = IngestionState(status: IngestionStatus.failed, report: state.report, message: '$e');
    } finally {
      ref.invalidate(longformFeedProvider);
      ref.invalidate(shortsFeedProvider);
      ref.invalidate(conceptDetailProvider);
      ref.invalidate(libraryStatsProvider);
    }
  }

  /// Path B over the whole curated pool (resumable; already-filled theorems are skipped).
  Future<void> buildTheoremPool() =>
      _run((s, p) => s.buildTheoremPool(onProgress: p, isCancelled: () => _cancel));

  /// "Find videos" for one concept: Path A for material concepts, Path B for pool theorems.
  Future<void> findVideos(String conceptId) => _run((s, p) => s.ingestForConcept(conceptId, onProgress: p));

  void cancel() => _cancel = true;
}

final ingestionControllerProvider = NotifierProvider<IngestionController, IngestionState>(IngestionController.new);
