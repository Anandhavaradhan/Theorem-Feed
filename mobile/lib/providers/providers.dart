import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/i18n.dart';
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
import '../services/preloader.dart';
import '../services/background_work.dart';
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

final feedServiceProvider = Provider<FeedService>((ref) => FeedService(ref.watch(databaseProvider), shortsSeed: _shortsMixSeed));
final conceptServiceProvider = Provider<ConceptService>((ref) => ConceptService(ref.watch(databaseProvider)));

final longformFeedProvider = FutureProvider<FeedResponse>((ref) async => ref.watch(feedServiceProvider).longform());
/// Keeps finding videos / reading a PDF going in the background (Android
/// foreground service with a notification). Off under `flutter test`.
final backgroundKeeperProvider = Provider<BackgroundKeeper>((ref) {
  if (Platform.environment['FLUTTER_TEST'] == 'true' || !Platform.isAndroid) return NoBackgroundKeeper();
  return ForegroundServiceKeeper();
});

/// One shuffle per app session: Shorts is a mix of everything, and it doesn't
/// reshuffle under you while new shorts are added.
final _shortsMixSeed = DateTime.now().microsecondsSinceEpoch;

/// Looks up the first Home videos' streams in the background, one at a time,
/// so tapping one starts playing at once. Off under `flutter test` (no YouTube).
final homePreloaderProvider = Provider<Preloader?>((ref) {
  if (Platform.environment['FLUTTER_TEST'] == 'true') return null;
  return Preloader((id) => ref.read(resolverProvider).resolve(id), ahead: 4);
});

final shortsFeedProvider = FutureProvider<FeedResponse>(
    (ref) async => ref.watch(feedServiceProvider).shorts(limit: 200, mixSeed: _shortsMixSeed));

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

enum IngestionStatus { idle, preparingModel, running, stopped, done, failed }

class IngestionState {
  const IngestionState(
      {this.status = IngestionStatus.idle,
      this.label = '',
      this.report,
      this.message,
      this.modelProgress,
      this.ranking = false,
      this.round = 0});
  final IngestionStatus status;
  final String label; // concept currently being searched
  final int round; // keep-filling round (0 = a one-off search)
  final IngestReport? report;
  final String? message;
  final double? modelProgress; // 0..1 while the model downloads
  final bool ranking; // judging relevance (after finding videos)
  bool get isBusy => status == IngestionStatus.preparingModel || status == IngestionStatus.running;
}

/// Settings key: concepts still to search after Stop (JSON list), so Continue
/// works even after the app was closed.
const ingestResumeKey = 'ingest_resume';

/// Settings: where the keep-filling rounds are ({"round": 2, "ids": [...]}), and
/// whether you stopped them (then they wait for Continue, even after a restart).
const fillResumeKey = 'fill_resume';
const fillStoppedKey = 'fill_stopped';
const _spokenCheckedKey = 'spoken_language_checked';

class IngestionController extends Notifier<IngestionState> {
  /// Each run has a number; Stop or a newer run makes older ones stop.
  int _runId = 0;
  int _stoppedRun = -1;
  Future<void>? _current;
  Future<void> Function()? _resume;

  @override
  IngestionState build() {
    final db = ref.read(databaseProvider);
    final fill = _savedFill();
    if (fill != null && db.getSetting(fillStoppedKey) == '1') {
      _resume = () => fillLibrary(startRound: fill.round, ids: fill.ids);
      return IngestionState(status: IngestionStatus.stopped, round: fill.round);
    }
    final saved = parseJsonList(db.getSetting(ingestResumeKey));
    if (saved.isEmpty) return const IngestionState();
    _resume = () => findVideosFor(saved);
    return const IngestionState(status: IngestionStatus.stopped);
  }

  ({int round, List<String> ids})? _savedFill() {
    final raw = ref.read(databaseProvider).getSetting(fillResumeKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (round: j['round'] as int, ids: (j['ids'] as List).cast<String>());
    } catch (_) {
      return null;
    }
  }

  /// Keeps adding long videos and shorts for every concept of your notes, round
  /// after round (3 more of each per round), until each has
  /// [IngestionService.maxPerKind] of both or YouTube has nothing new. Runs
  /// after an upload and when the app opens; Stop pauses it until Continue.
  Future<void> fillLibrary({int startRound = 1, List<String>? ids}) {
    final db = ref.read(databaseProvider);
    db.setSetting(fillStoppedKey, '0');
    var round = startRound;
    var remaining = ids;
    return _run((s, p, stopped) async {
      final total = IngestReport();
      state = IngestionState(status: IngestionStatus.running, round: round);
      for (; round <= IngestionService.maxRounds; round++) {
        final target = IngestionService.targetFor(round);
        final todo = remaining ?? s.conceptsBelow(target);
        remaining = null;
        final freshBefore = total.fresh;
        for (var i = 0; i < todo.length; i++) {
          if (stopped()) break;
          remaining = todo.sublist(i);
          db.setSetting(fillResumeKey, jsonEncode({'round': round, 'ids': remaining}));
          if (!s.isActiveConcept(todo[i])) continue;
          final r = await s.fillConcept(todo[i], round: round, onProgress: (label, r) {
            p(label, IngestReport()
              ..checked = total.checked + r.checked
              ..aiRead = total.aiRead + r.aiRead
              ..accepted = total.accepted + r.accepted
              ..acceptedShorts = total.acceptedShorts + r.acceptedShorts);
            state = IngestionState(status: IngestionStatus.running, label: label, report: state.report, round: round);
          });
          total
            ..checked += r.checked
            ..aiRead += r.aiRead
            ..accepted += r.accepted
            ..acceptedShorts += r.acceptedShorts
            ..fresh += r.fresh;
          total.errors.addAll(r.errors);
        }
        if (stopped()) return total;
        remaining = null;
        // A whole round with nothing new from YouTube: the library is as full as it gets.
        if (todo.isEmpty || (round > 1 && total.fresh == freshBefore)) break;
      }
      db.setSetting(fillResumeKey, '');
      return total;
    }, resume: () => fillLibrary(startRound: round, ids: remaining));
  }

  /// "Find more videos" for a chapter or PDF: one more round for each of its
  /// concepts (3 more long videos and 3 more shorts each, with new wording).
  Future<void> findMoreFor(Set<String> conceptIds) => _run((s, p, stopped) async {
        final total = IngestReport();
        for (final id in conceptIds) {
          if (stopped()) break;
          if (!s.isActiveConcept(id)) continue;
          final c = s.videoCounts(id);
          final round = IngestionService.roundAfter(c.long < c.short ? c.long : c.short);
          final r = await s.fillConcept(id, round: round, onProgress: (label, r) {
            p(label, IngestReport()
              ..checked = total.checked + r.checked
              ..accepted = total.accepted + r.accepted);
          });
          total
            ..checked += r.checked
            ..accepted += r.accepted;
        }
        return total;
      }, resume: () => findMoreFor(conceptIds));

  /// At start-up: continue the keep-filling rounds unless you stopped them.
  Future<void> autoFill() async {
    final db = ref.read(databaseProvider);
    if (db.getSetting(fillStoppedKey) == '1' || state.isBusy) return;
    if (db.select('SELECT 1 FROM user_active_concepts LIMIT 1').isEmpty) return;
    final fill = _savedFill();
    await fillLibrary(startRound: fill?.round ?? 1, ids: fill?.ids);
  }

  bool get canContinue => _resume != null;

  /// Completes when the current (or last) run has wound down.
  Future<void> get idle => _current ?? Future<void>.value();

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

  Future<void> _run(Future<IngestReport> Function(IngestionService s, IngestProgress p, bool Function() stopped) job,
      {bool quiet = false, bool rank = true, bool clearsSaved = false, required Future<void> Function() resume}) async {
    if (state.isBusy) return;
    final id = ++_runId;
    bool stopped() => _stoppedRun >= id || _runId != id;
    final done = Completer<void>();
    _current = done.future;
    _resume = resume;
    try {
      if (!await prepareModel()) return;
      if (stopped()) return;
      final svc = IngestionService(
        db: ref.read(databaseProvider),
        source: ref.read(videoSourceProvider),
        model: ref.read(jsonModelProvider),
        speechProbe: ref.read(speechProbeProvider),
        isCancelled: stopped,
      );
      state = const IngestionState(status: IngestionStatus.running);
      if (!quiet) {
        unawaited(ref.read(backgroundKeeperProvider).start(
            title: t('bg.finding'), text: t('bg.starting'), onStop: cancel));
      }
      var lastLabel = '';
      final report = await job(svc, (label, r) {
        if (stopped()) return; // the banner already says Stopped
        state = IngestionState(status: IngestionStatus.running, label: label, report: r, round: state.round);
        if (!quiet && label != lastLabel) {
          lastLabel = label;
          unawaited(ref.read(backgroundKeeperProvider).update(state.round > 0
              ? t('bg.round', {'round': state.round, 'concept': label, 'accepted': r.accepted})
              : t('bg.concept', {'concept': label, 'accepted': r.accepted})));
        }
        // Show new shorts as soon as they're accepted.
        ref.invalidate(shortsFeedProvider);
      }, stopped);
      // §9: judge the new candidates for your material's concepts (cached; only new pairs reach the model).
      if (rank && !stopped()) {
        await RelevanceService(ref.read(databaseProvider), ref.read(jsonModelProvider)).rankActiveConcepts(
          isCancelled: stopped,
          onProgress: (concept, _) {
            if (stopped()) return;
            state = IngestionState(status: IngestionStatus.running, label: concept, report: report, ranking: true);
          },
        );
      }
      if (!stopped()) {
        if (clearsSaved) ref.read(databaseProvider).setSetting(ingestResumeKey, '[]');
        // A longer run stopped earlier can still be continued.
        final saved = parseJsonList(ref.read(databaseProvider).getSetting(ingestResumeKey));
        _resume = saved.isEmpty ? null : () => findVideosFor(saved);
        state = quiet ? const IngestionState() : IngestionState(status: IngestionStatus.done, report: report);
      }
    } catch (e) {
      if (!stopped()) state = IngestionState(status: IngestionStatus.failed, report: state.report, message: '$e');
    } finally {
      done.complete();
      if (!quiet) unawaited(ref.read(backgroundKeeperProvider).stop());
      ref.invalidate(longformFeedProvider);
      ref.invalidate(shortsFeedProvider);
      ref.invalidate(conceptDetailProvider);
      ref.invalidate(libraryStatsProvider);
    }
  }

  /// Path B over the whole curated pool (resumable).
  Future<void> buildTheoremPool() =>
      _run((s, p, stopped) => s.buildTheoremPool(onProgress: p), resume: buildTheoremPool);

  /// Path B for the next couple of theorems: the Shorts tab calls this as you scroll.
  Future<void> fillShorts({int theorems = 2}) => _run(
      (s, p, stopped) => s.buildTheoremPool(onProgress: p, maxTheorems: theorems),
      quiet: true,
      rank: false,
      resume: () => fillShorts(theorems: theorems));

  /// "Find videos" for one concept: Path A for material concepts, Path B for pool theorems.
  Future<void> findVideos(String conceptId) => findVideosFor([conceptId]);

  /// Finds videos for several concepts in a row (after an upload, or one from a
  /// "Find videos" button). After Stop, Continue picks up at the concept that
  /// was interrupted; videos already decided are never checked again.
  Future<void> findVideosFor(List<String> conceptIds) {
    final db = ref.read(databaseProvider);
    // A one-concept search doesn't replace the saved place of a longer stopped run.
    final persist = conceptIds.length > 1;
    var remaining = List.of(conceptIds);
    return _run((s, p, stopped) async {
      final total = IngestReport();
      for (var i = 0; i < conceptIds.length; i++) {
        final id = conceptIds[i];
        if (stopped()) break;
        remaining = conceptIds.sublist(i);
        if (persist) db.setSetting(ingestResumeKey, jsonList(remaining));
        if (!s.canIngest(id)) continue;
        // The next concept's YouTube search runs while this one is checked.
        if (i + 1 < conceptIds.length) s.warmUp(conceptIds[i + 1]);
        final r = await s.ingestForConcept(id, onProgress: (label, r) {
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
    }, clearsSaved: persist, resume: () => findVideosFor(remaining));
  }

  /// Stop: the banner says so at once; the work halts before its next video or
  /// AI check (an AI answer already being written finishes first).
  void cancel() {
    if (!state.isBusy) return;
    _stoppedRun = _runId;
    if (state.round > 0) ref.read(databaseProvider).setSetting(fillStoppedKey, '1');
    state = IngestionState(status: IngestionStatus.stopped, report: state.report, label: state.label, round: state.round);
  }

  /// Continue after Stop (also after the app was closed). Waits for the stopped
  /// run to wind down first.
  Future<void> resume() async {
    final r = _resume;
    if (r == null || state.isBusy) return;
    // The stopped run halts by itself at its next step (a newer run stops it);
    // a hung YouTube request must not hold Continue up, so wait 2 s at most.
    state = const IngestionState(status: IngestionStatus.preparingModel);
    await (_current ?? Future<void>.value()).timeout(const Duration(seconds: 2), onTimeout: () {});
    state = const IngestionState();
    await r();
  }

  /// Hide the banner. A stopped run can still be continued from a concept's
  /// "Find videos" button; the saved place is kept.
  void dismiss() => state = const IngestionState();

  /// English only, for videos added before the stricter checks: runs quietly in
  /// the background at start-up; each video's spoken language is asked once.
  Future<void> recheckLanguages() async {
    final db = ref.read(databaseProvider);
    final checked = parseJsonList(db.getSetting(_spokenCheckedKey)).toSet();
    final svc = IngestionService(
      db: db,
      source: ref.read(videoSourceProvider),
      model: ref.read(jsonModelProvider),
      isCancelled: () => state.isBusy, // never competes with a search you started
    );
    // Videos in another sense of the concept than your notes' ("Quantum superposition").
    var removed = svc.recheckTopics();
    removed += await svc.recheckLanguages(checked: checked, onChecked: (yt) {
      checked.add(yt);
      db.setSetting(_spokenCheckedKey, jsonList(checked.toList()));
    });
    if (removed > 0) {
      ref.invalidate(longformFeedProvider);
      ref.invalidate(shortsFeedProvider);
      ref.invalidate(conceptDetailProvider);
    }
  }
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

/// Settings key: also run the AI over every section (slower).
const deepReadKey = 'deep_read';

final deepReadProvider = Provider<bool>((ref) => ref.watch(databaseProvider).getSetting(deepReadKey) == '1');

enum UploadStatus { idle, preparingModel, processing, stopped, done, failed }

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
  /// Each upload has a number; Stop or a newer upload makes older ones stop.
  int _runId = 0;
  int _stoppedRun = -1;
  String? _lastPath;
  Future<void>? _current;

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
    final id = ++_runId;
    bool stopped() => _stoppedRun >= id || _runId != id;
    _lastPath = path;
    final done = Completer<void>();
    _current = done.future;
    final keeper = ref.read(backgroundKeeperProvider);
    unawaited(keeper.start(title: t('bg.reading'), text: p.basename(path), onStop: cancel));
    try {
      await _upload(path, stopped);
    } finally {
      done.complete();
      // Finding videos starts right after a successful upload and takes over the notification.
      if (!ref.read(ingestionControllerProvider).isBusy) unawaited(keeper.stop());
    }
  }

  Future<void> _upload(String path, bool Function() stopped) async {
    JsonModel? model;
    var rulesOnly = false;
    state = const UploadState(status: UploadStatus.preparingModel);
    try {
      await ref.read(modelLoaderProvider)((f) {
        if (!stopped()) state = UploadState(status: UploadStatus.preparingModel, modelProgress: f);
      });
      ref.read(databaseProvider).setSetting('local_model_ready', '1');
      ref.invalidate(modelReadyProvider);
      model = ref.read(jsonModelProvider);
    } catch (_) {
      rulesOnly = true; // e.g. offline on first use: still read labelled theorems/definitions
    }
    if (stopped()) return;
    try {
      final db = ref.read(databaseProvider);
      final svc = MaterialService(db,
          pdf: ref.read(pdfTextSourceProvider), model: model, deepRead: db.getSetting(deepReadKey) == '1');
      final result = await svc.upload(
        path,
        isCancelled: stopped,
        onProgress: (stage, done, total) {
          if (stopped()) return; // the banner already says Stopped
          state = UploadState(status: UploadStatus.processing, stage: stage, done: done, total: total, rulesOnly: rulesOnly);
        },
      );
      if (stopped()) return;
      state = UploadState(status: UploadStatus.done, result: result, rulesOnly: rulesOnly);
      _refresh();
      // §6.4 step 5: scoped ingestion (Path A) for new concepts with zero videos.
      if (result.gapConceptIds.isNotEmpty) {
        // A new PDF: rounds start again from round 1 for every concept (filled ones are skipped).
        ref.read(databaseProvider).setSetting(fillResumeKey, '');
        unawaited(ref.read(ingestionControllerProvider.notifier).fillLibrary());
      }
    } on NoTextLayer catch (e) {
      if (!stopped()) state = UploadState(status: UploadStatus.failed, message: '$e');
    } on UploadCancelled {
      // The banner already says Stopped; nothing was saved.
    } catch (e) {
      if (!stopped()) state = UploadState(status: UploadStatus.failed, message: '$e');
    }
  }

  /// Stop: the banner says so at once; nothing from this upload is saved.
  void cancel() {
    if (!state.isBusy) return;
    _stoppedRun = _runId;
    state = const UploadState(status: UploadStatus.stopped);
  }

  /// Continue a stopped upload: reads the same PDF again (the rules take about a second).
  Future<void> resume() async {
    final path = _lastPath;
    if (path == null || state.isBusy) return;
    state = const UploadState(status: UploadStatus.preparingModel);
    await (_current ?? Future<void>.value()).timeout(const Duration(seconds: 2), onTimeout: () {});
    state = const UploadState();
    await upload(path);
  }

  bool get canContinue => _lastPath != null;
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

const homeTab = 0, shortsTab = 1, materialTab = 2, youTab = 3;

/// Selected bottom-navigation tab: [homeTab], [shortsTab], [materialTab], [youTab].
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
  const SearchQuery(this.text, {this.theoremOnly = false, this.scope});
  final String text;
  final bool theoremOnly;

  /// Search only this chapter's (or PDF's) concepts; null = everything.
  final FeedScope? scope;
}

class SearchQueryController extends Notifier<SearchQuery> {
  @override
  SearchQuery build() => const SearchQuery('');
  void set(String text) => state = SearchQuery(text, scope: state.scope);
  void theoremOnly() => state = SearchQuery(state.text, theoremOnly: true, scope: state.scope);
  void scopeTo(FeedScope? scope) => state = SearchQuery('', scope: scope);
}

final searchQueryProvider = NotifierProvider<SearchQueryController, SearchQuery>(SearchQueryController.new);

final searchResultsProvider = FutureProvider.autoDispose<SearchResponse>((ref) async {
  final q = ref.watch(searchQueryProvider);
  // Re-run when the library changes (new videos, material changes, judgements).
  ref.watch(longformFeedProvider);
  final r = ref.watch(searchServiceProvider).search(q.text, theoremOnly: q.theoremOnly);
  final scope = q.scope;
  if (scope == null || q.text.trim().isEmpty) return r;
  final groups = [for (final g in r.groups) if (scope.conceptIds.contains(g.conceptId)) g];
  return SearchResponse(
    understanding: r.understanding,
    groups: groups,
    outOfScope: groups.isEmpty ? const OutOfScope() : null,
    materialInactive: r.materialInactive,
    theoremOnly: r.theoremOnly,
  );
});

// --- Home chips: All, each PDF, each chapter -------------------------------------

class ActiveConcept {
  ActiveConcept(this.id, this.name);
  final String id;
  final String name;
}

final activeConceptsProvider = FutureProvider<List<ActiveConcept>>((ref) async {
  ref.watch(longformFeedProvider); // refresh with the feed
  return [
    for (final r in ref.watch(databaseProvider).select('''
      SELECT c.id, c.canonical_name FROM user_active_concepts u JOIN concepts c ON c.id = u.concept_id
      ORDER BY u.priority DESC, c.canonical_name LIMIT 30'''))
      ActiveConcept(r['id'] as String, r['canonical_name'] as String),
  ];
});

/// The chips above Home: each active PDF (when there are several) and its chapters.
final feedScopesProvider = FutureProvider<List<FeedScope>>((ref) async {
  ref.watch(longformFeedProvider); // refresh with the feed
  return ref.watch(feedServiceProvider).scopes();
});

/// The selected chip's key; null = All.
class HomeFilter extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? scopeKey) => state = scopeKey;
}

final homeFilterProvider = NotifierProvider<HomeFilter, String?>(HomeFilter.new);

/// What Home shows: the general feed, or the selected PDF's / chapter's feed.
final homeFeedProvider = FutureProvider<FeedResponse>((ref) async {
  final all = await ref.watch(longformFeedProvider.future);
  final key = ref.watch(homeFilterProvider);
  if (key == null || all.needsUpload) return all;
  final scope = (await ref.watch(feedScopesProvider.future)).where((s) => s.key == key).firstOrNull;
  if (scope == null) return all; // the PDF was archived: back to All
  return ref.watch(feedServiceProvider).longform(onlyConcepts: scope.conceptIds);
});

final historyProvider = FutureProvider.autoDispose((ref) async {
  ref.watch(longformFeedProvider);
  return ref.watch(watchHistoryProvider).history();
});

final savedProvider = FutureProvider.autoDispose((ref) async {
  ref.watch(longformFeedProvider);
  return ref.watch(watchHistoryProvider).saved();
});
