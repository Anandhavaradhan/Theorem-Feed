import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../models/feed.dart';
import '../models/resolved_video.dart';
import '../services/llm.dart';
import '../services/local_llm.dart';
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

// --- On-device AI model + ingestion -------------------------------------------

final localModelProvider = Provider<LocalLlmModel>((ref) {
  final m = LocalLlmModel();
  ref.onDispose(m.dispose);
  return m;
});

/// The model the gates use; overridden with a fake in tests.
final jsonModelProvider = Provider<JsonModel>((ref) => ref.watch(localModelProvider));

/// Downloads (once) and loads the on-device model; overridden in tests.
final modelLoaderProvider = Provider<Future<void> Function(void Function(double? fraction) onProgress)>(
  (ref) => (onProgress) => ref.read(localModelProvider).ensureLoaded(onProgress: onProgress),
);

const _modelReadyKey = 'local_model_ready';

/// Whether the model has been downloaded on this device before.
final modelReadyProvider = Provider<bool>((ref) => ref.watch(databaseProvider).getSetting(_modelReadyKey) == '1');

final videoSourceProvider = Provider<VideoSource>((ref) {
  final s = YoutubeExplodeSource();
  ref.onDispose(s.close);
  return s;
});

final speechProbeProvider = Provider<SpeechLanguageProbe?>((ref) => WhisperSpeechProbe());

enum IngestionStatus { idle, preparingModel, running, done, failed }

class IngestionState {
  const IngestionState({this.status = IngestionStatus.idle, this.label = '', this.report, this.message, this.modelProgress});
  final IngestionStatus status;
  final String label; // concept currently being searched
  final IngestReport? report;
  final String? message;
  final double? modelProgress; // 0..1 while the model downloads
  bool get isBusy => status == IngestionStatus.preparingModel || status == IngestionStatus.running;
}

class IngestionController extends Notifier<IngestionState> {
  bool _cancel = false;

  @override
  IngestionState build() => const IngestionState();

  /// Download + load the model, reporting progress. Returns false on failure.
  Future<bool> prepareModel() async {
    state = const IngestionState(status: IngestionStatus.preparingModel);
    try {
      await ref.read(modelLoaderProvider)((f) {
        state = IngestionState(status: IngestionStatus.preparingModel, modelProgress: f);
      });
      ref.read(databaseProvider).setSetting(_modelReadyKey, '1');
      ref.invalidate(modelReadyProvider);
      state = const IngestionState();
      return true;
    } catch (e) {
      state = IngestionState(status: IngestionStatus.failed, message: '$e');
      return false;
    }
  }

  Future<void> _run(Future<IngestReport> Function(IngestionService s, IngestProgress p) job, {bool quiet = false}) async {
    if (state.isBusy) return;
    if (!await prepareModel()) return;
    _cancel = false;
    final svc = IngestionService(
      db: ref.read(databaseProvider),
      source: ref.read(videoSourceProvider),
      model: ref.read(jsonModelProvider),
      speechProbe: ref.read(speechProbeProvider),
    );
    state = const IngestionState(status: IngestionStatus.running);
    try {
      final report = await job(svc, (label, r) {
        state = IngestionState(status: IngestionStatus.running, label: label, report: r);
        // Show new shorts as soon as they're accepted.
        ref.invalidate(shortsFeedProvider);
      });
      state = quiet ? const IngestionState() : IngestionState(status: IngestionStatus.done, report: report);
    } catch (e) {
      state = IngestionState(status: IngestionStatus.failed, report: state.report, message: '$e');
    } finally {
      ref.invalidate(longformFeedProvider);
      ref.invalidate(shortsFeedProvider);
      ref.invalidate(conceptDetailProvider);
      ref.invalidate(libraryStatsProvider);
    }
  }

  /// Path B over the whole curated pool (resumable).
  Future<void> buildTheoremPool() =>
      _run((s, p) => s.buildTheoremPool(onProgress: p, isCancelled: () => _cancel));

  /// Path B for the next couple of theorems: the Shorts tab calls this as you scroll.
  Future<void> fillShorts({int theorems = 2}) =>
      _run((s, p) => s.buildTheoremPool(onProgress: p, isCancelled: () => _cancel, maxTheorems: theorems), quiet: true);

  /// "Find videos" for one concept: Path A for material concepts, Path B for pool theorems.
  Future<void> findVideos(String conceptId) => _run((s, p) => s.ingestForConcept(conceptId, onProgress: p));

  void cancel() => _cancel = true;
}

final ingestionControllerProvider = NotifierProvider<IngestionController, IngestionState>(IngestionController.new);
