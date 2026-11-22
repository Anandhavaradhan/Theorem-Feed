import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../models/feed.dart';
import '../models/resolved_video.dart';
import '../services/llm.dart';
import '../services/local_llm.dart';
import '../services/material/material_service.dart';
import '../services/material/pdf_text.dart';
import '../services/relevance/evaluation.dart';
import '../services/relevance/relevance_service.dart';
import '../services/search/search_service.dart';
import '../services/concept_service.dart';
import '../services/feed_service.dart';
import '../services/gates.dart';
import '../services/ingestion_service.dart';
import '../services/resolver.dart';
import '../services/watch_history.dart';
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

final watchHistoryProvider = Provider<WatchHistoryService>((ref) => WatchHistoryService(ref.watch(databaseProvider)));

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
  const IngestionState(
      {this.status = IngestionStatus.idle, this.label = '', this.report, this.message, this.modelProgress, this.ranking = false});
  final IngestionStatus status;
  final String label; // concept currently being searched
  final IngestReport? report;
  final String? message;
  final double? modelProgress; // 0..1 while the model downloads
  final bool ranking; // judging relevance (after finding videos)
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

  Future<void> _run(Future<IngestReport> Function(IngestionService s, IngestProgress p) job,
      {bool quiet = false, bool rank = true}) async {
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
      // §9: judge the new candidates for your material's concepts (cached; only new pairs reach the model).
      if (rank && !_cancel) {
        await RelevanceService(ref.read(databaseProvider), ref.read(jsonModelProvider)).rankActiveConcepts(
          isCancelled: () => _cancel,
          onProgress: (concept, _) =>
              state = IngestionState(status: IngestionStatus.running, label: concept, report: report, ranking: true),
        );
      }
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
  Future<void> fillShorts({int theorems = 2}) => _run(
      (s, p) => s.buildTheoremPool(onProgress: p, isCancelled: () => _cancel, maxTheorems: theorems),
      quiet: true,
      rank: false);

  /// "Find videos" for one concept: Path A for material concepts, Path B for pool theorems.
  Future<void> findVideos(String conceptId) => _run((s, p) => s.ingestForConcept(conceptId, onProgress: p));

  /// Path A for several material concepts in a row (after an upload).
  Future<void> findVideosFor(List<String> conceptIds) => _run((s, p) async {
        final total = IngestReport();
        for (final id in conceptIds) {
          if (_cancel) break;
          if (!s.isActiveConcept(id)) continue;
          final r = await s.ingestMaterialConcept(id, onProgress: (label, r) {
            p(label, IngestReport()
              ..checked = total.checked + r.checked
              ..accepted = total.accepted + r.accepted);
          });
          total.checked += r.checked;
          total.accepted += r.accepted;
          for (final e in r.rejected.entries) {
            total.rejected[e.key] = (total.rejected[e.key] ?? 0) + e.value;
          }
          total.errors.addAll(r.errors);
        }
        return total;
      });

  void cancel() => _cancel = true;
}

final ingestionControllerProvider = NotifierProvider<IngestionController, IngestionState>(IngestionController.new);

// --- Material (§6) ------------------------------------------------------------

final pdfTextSourceProvider = Provider<PdfTextSource>((ref) => PdfrxTextSource());

final materialServiceProvider = Provider<MaterialService>(
  (ref) => MaterialService(ref.watch(databaseProvider), pdf: ref.watch(pdfTextSourceProvider)),
);

final materialsProvider = FutureProvider<List<MaterialSummary>>((ref) async => ref.watch(materialServiceProvider).list());
final studyingNowProvider = FutureProvider<StudyingNow>((ref) async => ref.watch(materialServiceProvider).studyingNow());
final materialConceptsProvider = FutureProvider.autoDispose.family<List<MaterialConceptRow>, String>(
  (ref, id) async => ref.watch(materialServiceProvider).conceptsOf(id),
);

/// Picks a PDF; overridden in tests.
final pdfPickerProvider = Provider<Future<String?> Function()>((ref) => () async {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
      return files.isEmpty ? null : files.first.path;
    });

/// How many new concepts get automatic video search right after an upload;
/// the rest stay as coverage-gap cards with a "Find videos" button.
const autoIngestAfterUpload = 15;

enum UploadStatus { idle, preparingModel, processing, done, failed }

class UploadState {
  const UploadState({
    this.status = UploadStatus.idle,
    this.stage,
    this.done = 0,
    this.total = 0,
    this.modelProgress,
    this.result,
    this.message,
    this.rulesOnly = false,
  });
  final UploadStatus status;
  final UploadStage? stage;
  final int done;
  final int total;
  final double? modelProgress;
  final UploadResult? result;
  final String? message;
  final bool rulesOnly; // the model couldn't load; labelled theorems/definitions only
  bool get isBusy => status == UploadStatus.preparingModel || status == UploadStatus.processing;
}

class MaterialController extends Notifier<UploadState> {
  bool _cancel = false;

  @override
  UploadState build() => const UploadState();

  void _refresh() {
    ref.invalidate(materialsProvider);
    ref.invalidate(studyingNowProvider);
    ref.invalidate(materialConceptsProvider);
    ref.invalidate(longformFeedProvider);
    ref.invalidate(shortsFeedProvider);
    ref.invalidate(conceptDetailProvider);
  }

  Future<void> pickAndUpload() async {
    if (state.isBusy) return;
    final path = await ref.read(pdfPickerProvider)();
    if (path != null) await upload(path);
  }

  Future<void> upload(String path) async {
    if (state.isBusy) return;
    _cancel = false;
    JsonModel? model;
    var rulesOnly = false;
    state = const UploadState(status: UploadStatus.preparingModel);
    try {
      await ref.read(modelLoaderProvider)((f) => state = UploadState(status: UploadStatus.preparingModel, modelProgress: f));
      ref.read(databaseProvider).setSetting('local_model_ready', '1');
      ref.invalidate(modelReadyProvider);
      model = ref.read(jsonModelProvider);
    } catch (_) {
      rulesOnly = true; // e.g. offline on first use: still read labelled theorems/definitions
    }
    try {
      final svc = MaterialService(ref.read(databaseProvider), pdf: ref.read(pdfTextSourceProvider), model: model);
      final result = await svc.upload(
        path,
        isCancelled: () => _cancel,
        onProgress: (stage, done, total) => state =
            UploadState(status: UploadStatus.processing, stage: stage, done: done, total: total, rulesOnly: rulesOnly),
      );
      state = UploadState(status: UploadStatus.done, result: result, rulesOnly: rulesOnly);
      _refresh();
      // §6.4 step 5: scoped ingestion (Path A) for new concepts with zero videos.
      if (result.gapConceptIds.isNotEmpty) {
        unawaited(ref
            .read(ingestionControllerProvider.notifier)
            .findVideosFor(result.gapConceptIds.take(autoIngestAfterUpload).toList()));
      }
    } on NoTextLayer catch (e) {
      state = UploadState(status: UploadStatus.failed, message: '$e');
    } on UploadCancelled {
      state = const UploadState();
    } catch (e) {
      state = UploadState(status: UploadStatus.failed, message: '$e');
    }
  }

  void cancel() => _cancel = true;
  void dismiss() => state = const UploadState();

  void archive(String id) => _apply(() => ref.read(materialServiceProvider).archive(id));
  void delete(String id) => _apply(() => ref.read(materialServiceProvider).delete(id));
  void reactivate(String id) => _apply(() => ref.read(materialServiceProvider).reactivate(id));
  void rename(String id, String title) => _apply(() => ref.read(materialServiceProvider).rename(id, title));
  void setExamDate(String id, DateTime? date) => _apply(() => ref.read(materialServiceProvider).setExamDate(id, date));
  void autoArchive() => _apply(() => ref.read(materialServiceProvider).autoArchivePastExams());

  void _apply(void Function() action) {
    action();
    _refresh();
  }
}

final materialControllerProvider = NotifierProvider<MaterialController, UploadState>(MaterialController.new);

/// Selected bottom-navigation tab (0 Home, 1 Shorts, 2 Search, 3 My Material).
class SelectedTab extends Notifier<int> {
  @override
  int build() => 0;
  void select(int i) => state = i;
}

final tabProvider = NotifierProvider<SelectedTab, int>(SelectedTab.new);

// --- Relevance evaluation (§9.3) -------------------------------------------------

final evaluationServiceProvider = Provider<EvaluationService>((ref) => EvaluationService(ref.watch(databaseProvider)));

final goldenProgressProvider =
    FutureProvider.autoDispose<GoldenProgress>((ref) async => ref.watch(evaluationServiceProvider).progress());

final goldenLabelProvider = FutureProvider.autoDispose.family<GoldenLabel?, (String, String)>(
  (ref, key) async => ref.watch(evaluationServiceProvider).labelOf(key.$1, key.$2),
);

enum EvalStatus { idle, running, done, failed }

class EvalState {
  const EvalState({this.status = EvalStatus.idle, this.done = 0, this.total = 0, this.report, this.message});
  final EvalStatus status;
  final int done;
  final int total;
  final EvalReport? report;
  final String? message;
}

class EvaluationController extends Notifier<EvalState> {
  @override
  EvalState build() => const EvalState();

  void label(String conceptId, String videoId, GoldenLabel? label) {
    ref.read(evaluationServiceProvider).setLabel(conceptId, videoId, label);
    ref.invalidate(goldenLabelProvider);
    ref.invalidate(goldenProgressProvider);
  }

  /// Judges the labelled concepts (cache misses only) and computes the metrics.
  Future<void> run() async {
    if (state.status == EvalStatus.running) return;
    final eval = ref.read(evaluationServiceProvider);
    final concepts = eval.labelledConcepts();
    state = EvalState(status: EvalStatus.running, total: concepts.length);
    try {
      await ref.read(modelLoaderProvider)((_) {});
      final relevance = RelevanceService(ref.read(databaseProvider), ref.read(jsonModelProvider));
      for (var i = 0; i < concepts.length; i++) {
        await relevance.rankConcept(concepts[i]);
        state = EvalState(status: EvalStatus.running, done: i + 1, total: concepts.length);
      }
      state = EvalState(status: EvalStatus.done, report: eval.evaluate(relevance));
      ref.invalidate(longformFeedProvider);
    } catch (e) {
      state = EvalState(status: EvalStatus.failed, message: '$e');
    }
  }
}

final evaluationControllerProvider = NotifierProvider<EvaluationController, EvalState>(EvaluationController.new);

// --- Search (§11) -----------------------------------------------------------------

final searchServiceProvider = Provider<SearchService>((ref) => SearchService(ref.watch(databaseProvider)));

class SearchQuery {
  const SearchQuery(this.text, {this.theoremOnly = false});
  final String text;
  final bool theoremOnly;
}

class SearchQueryController extends Notifier<SearchQuery> {
  @override
  SearchQuery build() => const SearchQuery('');
  void set(String text) => state = SearchQuery(text);
  void theoremOnly() => state = SearchQuery(state.text, theoremOnly: true);
}

final searchQueryProvider = NotifierProvider<SearchQueryController, SearchQuery>(SearchQueryController.new);

final searchResultsProvider = FutureProvider.autoDispose<SearchResponse>((ref) async {
  final q = ref.watch(searchQueryProvider);
  // Re-run when the library changes (new videos, material changes, judgements).
  ref.watch(longformFeedProvider);
  return ref.watch(searchServiceProvider).search(q.text, theoremOnly: q.theoremOnly);
});
