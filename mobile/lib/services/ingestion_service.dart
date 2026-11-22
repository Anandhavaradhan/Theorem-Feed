/// Scoped ingestion (§8). Exactly two paths, nothing else:
///
///   Path A  material-linked: a concept in user_active_concepts.
///   Path B  curated math theorem pool: a concept with in_theorem_pool AND subject='math'.
///
/// There is no "browse and ingest educational videos", no ingestion for
/// concepts outside active material or the theorem pool, and no background
/// job that wanders into neighbouring topics.
library;

import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import 'concept_matcher.dart';
import 'gates.dart';
import 'youtube_source.dart';
import 'llm.dart';

const shortMaxSeconds = 180;

/// Thrown when asked to ingest for a concept outside the two allowed paths.
class OutOfScopeIngestion implements Exception {
  OutOfScopeIngestion(this.message);
  final String message;
  @override
  String toString() => 'OutOfScopeIngestion($message)';
}

enum IngestPath { material, theoremPool }

class IngestReport {
  int checked = 0;
  int accepted = 0;
  final Map<String, int> rejected = {};
  final List<String> errors = [];
  void reject(String outcome) => rejected[outcome] = (rejected[outcome] ?? 0) + 1;
  @override
  String toString() => 'checked=$checked accepted=$accepted rejected=$rejected errors=${errors.length}';
}

typedef IngestProgress = void Function(String conceptName, IngestReport report);

class _Target {
  _Target(this.id, this.name, this.aliases, this.subject, this.type, this.path);
  final String id;
  final String name;
  final List<String> aliases;
  final String subject;
  final String type;
  final IngestPath path;
}

class IngestionService {
  IngestionService({
    required this._db,
    required this.source,
    required this.model,
    SpeechLanguageProbe? speechProbe,
    this.candidatesPerConcept = 8,
    this.acceptPerConcept = 3,
    this.prefetchAhead = 3,
  }) : _speech = speechProbe;

  final AppDatabase _db;
  final VideoSource source;
  final JsonModel model;
  final SpeechLanguageProbe? _speech;
  final int candidatesPerConcept;
  final int acceptPerConcept;

  /// How many upcoming candidates' details download in parallel with the current check.
  final int prefetchAhead;
  static const _uuid = Uuid();

  // --- scope ------------------------------------------------------------------

  bool isActiveConcept(String conceptId) =>
      _db.select('SELECT 1 FROM user_active_concepts WHERE concept_id = ?', [conceptId]).isNotEmpty;

  bool isPoolTheorem(String conceptId) => _db.select(
        "SELECT 1 FROM concepts WHERE id = ? AND in_theorem_pool = 1 AND subject = 'math'",
        [conceptId],
      ).isNotEmpty;

  bool canIngest(String conceptId) => isActiveConcept(conceptId) || isPoolTheorem(conceptId);

  _Target _target(String conceptId, IngestPath path) {
    final allowed = path == IngestPath.material ? isActiveConcept(conceptId) : isPoolTheorem(conceptId);
    if (!allowed) {
      throw OutOfScopeIngestion(path == IngestPath.material
          ? 'concept is not in your active material'
          : 'concept is not in the curated math theorem pool');
    }
    final r = _db.select('SELECT canonical_name, aliases, subject, type FROM concepts WHERE id = ?', [conceptId]).first;
    return _Target(conceptId, r['canonical_name'] as String, parseJsonList(r['aliases'] as String?),
        r['subject'] as String, r['type'] as String, path);
  }

  // --- public entry points ----------------------------------------------------

  /// Path A for one concept (coverage-gap "Find videos", concept detail, and —
  /// from Phase C — automatically after a material upload).
  Future<IngestReport> ingestMaterialConcept(String conceptId, {IngestProgress? onProgress}) =>
      _ingest(_target(conceptId, IngestPath.material), IngestReport(), onProgress);

  /// Path B for one pool theorem.
  Future<IngestReport> ingestPoolTheorem(String conceptId, {IngestProgress? onProgress}) =>
      _ingest(_target(conceptId, IngestPath.theoremPool), IngestReport(), onProgress);

  /// "Find videos" from the UI: Path A if the concept is in your material, else
  /// Path B if it's a pool theorem, else refused.
  Future<IngestReport> ingestForConcept(String conceptId, {IngestProgress? onProgress}) {
    if (isActiveConcept(conceptId)) return ingestMaterialConcept(conceptId, onProgress: onProgress);
    if (isPoolTheorem(conceptId)) return ingestPoolTheorem(conceptId, onProgress: onProgress);
    throw OutOfScopeIngestion('concept is neither in your material nor in the theorem pool');
  }

  /// Path B over the pool, in curated order. Theorems that already have
  /// [acceptPerConcept] pool shorts are skipped, so this is safe to re-run.
  /// [maxTheorems] limits one run (the Shorts tab fills a couple at a time as you scroll).
  Future<IngestReport> buildTheoremPool({IngestProgress? onProgress, bool Function()? isCancelled, int? maxTheorems}) async {
    final report = IngestReport();
    final theorems = _db.select('''
      SELECT c.id FROM concepts c
      WHERE c.in_theorem_pool = 1 AND c.subject = 'math'
        AND (SELECT count(*) FROM video_concepts vc JOIN videos v ON v.id = vc.video_id
             WHERE vc.concept_id = c.id AND vc.is_primary = 1 AND v.status = 'active'
               AND v.is_short = 1 AND v.in_theorem_pool = 1) < ?
      ORDER BY coalesce(c.pool_order, 1e9), c.canonical_name
    ''', [acceptPerConcept]);
    for (final row in maxTheorems == null ? theorems : theorems.take(maxTheorems)) {
      if (isCancelled?.call() ?? false) break;
      await _ingest(_target(row['id'] as String, IngestPath.theoremPool), report, onProgress);
    }
    return report;
  }

  // --- pipeline ---------------------------------------------------------------

  static const _subjectWord = {'physics': 'physics', 'math': 'math', 'cs': 'computer science'};

  /// The YouTube query. A short name ("Echo", "Phase", "Pitch") also matches
  /// songs, brands and games, so its subject is added ("Echo physics").
  String _query(_Target t) {
    final alias = t.aliases.where((a) => !t.name.toLowerCase().contains(a.toLowerCase())).firstOrNull;
    var base = alias == null ? t.name : '${t.name} $alias';
    final subject = _subjectWord[t.subject];
    if (t.path == IngestPath.material &&
        subject != null &&
        alias == null &&
        t.name.split(' ').length <= 2 &&
        !base.toLowerCase().contains(subject)) {
      base = '$base $subject';
    }
    return t.path == IngestPath.theoremPool ? '$base #shorts' : base;
  }

  final _searches = <String, Future<List<CandidateVideo>>>{};

  Future<List<CandidateVideo>> _search(_Target t) => _searches.putIfAbsent(t.id, () {
        final f = source.search(_query(t), limit: candidatesPerConcept);
        f.then((_) {}, onError: (_) {}); // surfaced when awaited
        return f;
      });

  /// Starts the YouTube search for a concept that will be checked next, so it
  /// is ready when the current concept finishes.
  void warmUp(String conceptId) {
    if (!canIngest(conceptId)) return;
    _search(_target(conceptId, isActiveConcept(conceptId) ? IngestPath.material : IngestPath.theoremPool));
  }

  /// Names of the other concepts in your active material (context for the rule check).
  List<String> _materialNames(String exceptId) => [
        for (final r in _db.select('''
          SELECT c.canonical_name FROM user_active_concepts u JOIN concepts c ON c.id = u.concept_id
          WHERE c.id != ? ORDER BY u.priority DESC LIMIT 200''', [exceptId]))
          r['canonical_name'] as String,
      ];

  Future<IngestReport> _ingest(_Target t, IngestReport report, IngestProgress? onProgress) async {
    onProgress?.call(t.name, report);
    List<CandidateVideo> candidates;
    try {
      candidates = await _search(t);
    } catch (e) {
      _searches.remove(t.id);
      report.errors.add('search "${t.name}": $e');
      return report;
    }
    _searches.remove(t.id); // a later run searches afresh
    final context = t.path == IngestPath.material ? _materialNames(t.id) : const <String>[];
    var acceptedHere = 0;
    // Prefetch: while one candidate is being judged, the next few candidates'
    // details (metadata, transcript, orientation) download in parallel.
    final details = <String, Future<VideoDetails>>{};
    Future<VideoDetails> detailsFor(CandidateVideo c) => details[c.id] ??= () {
          final f = source.details(c.id, needVertical: c.durationSec == null || c.durationSec! <= shortMaxSeconds);
          f.then((_) {}, onError: (_) {}); // errors surface when awaited, not as unhandled
          return f;
        }();
    final todo = [for (final c in candidates) if (!_alreadySeen(c.id)) c];
    // Videos without captions need the speech model, the slowest check by far;
    // they wait until the captioned ones have had their turn.
    final noCaptions = <CandidateVideo>[];

    Future<void> check(CandidateVideo c, {required bool allowSpeech}) async {
      String outcome;
      try {
        outcome = await _evaluate(c, t, detailsFor, context: context, allowSpeech: allowSpeech);
      } on ModelApiError catch (e) {
        if (e.isAuth) rethrow; // can't continue: the UI explains
        outcome = _log(c.id, 'error', '$e', t.id);
        report.errors.add('${c.id}: $e');
      } on QuotaExhausted {
        rethrow;
      } catch (e) {
        outcome = _log(c.id, 'error', '$e', t.id);
        report.errors.add('${c.id}: $e');
      }
      if (outcome == _deferred) {
        noCaptions.add(c);
        return;
      }
      report.checked++;
      if (outcome == 'accepted') {
        report.accepted++;
        acceptedHere++;
      } else if (outcome != 'error') {
        report.reject(outcome);
      }
      onProgress?.call(t.name, report);
    }

    for (var i = 0; i < todo.length; i++) {
      if (acceptedHere >= acceptPerConcept) break;
      for (final next in todo.skip(i).take(prefetchAhead + 1)) {
        if (_passesCheapChecks(next, t)) detailsFor(next);
      }
      await check(todo[i], allowSpeech: false);
    }
    for (final c in List.of(noCaptions)) {
      if (acceptedHere >= acceptPerConcept) break;
      await check(c, allowSpeech: true);
    }
    return report;
  }

  static const _deferred = '_deferred';

  bool _alreadySeen(String youtubeId) =>
      // Transient errors are retried on the next run; every other outcome is final.
      _db.select("SELECT 1 FROM ingest_log WHERE source_id = ? AND outcome != 'error'", [youtubeId]).isNotEmpty ||
      _db.select('SELECT 1 FROM videos WHERE source_id = ?', [youtubeId]).isNotEmpty;

  String _log(String youtubeId, String outcome, String reason, String conceptId) {
    _db.execute(
      'INSERT OR REPLACE INTO ingest_log (source_id, outcome, reason, concept_id, checked_at) VALUES (?, ?, ?, ?, ?)',
      [youtubeId, outcome, reason.length > 500 ? reason.substring(0, 500) : reason, conceptId, nowMs()],
    );
    return outcome;
  }

  /// Records a gate rejection in `videos` (status rejected_*) and the log.
  String _rejectVideo(String youtubeId, String status, String reason, _Target t,
      {required String title, required String description, int? durationSec, String? thumbnail}) {
    _db.execute(
      'INSERT OR IGNORE INTO videos (id, source, source_id, title, description, duration_sec, thumbnail_url, '
      "status, created_at) VALUES (?, 'youtube', ?, ?, ?, ?, ?, ?, ?)",
      [_uuid.v4(), youtubeId, title, description, durationSec, thumbnail, status, nowMs()],
    );
    return _log(youtubeId, status, reason, t.id);
  }

  /// The instant checks, without side effects (used to decide what to prefetch).
  bool _passesCheapChecks(CandidateVideo c, _Target t) =>
      !(t.path == IngestPath.theoremPool && (c.durationSec == null || c.durationSec! > shortMaxSeconds)) &&
      unsafeKeyword('${c.title}\n${c.description}') == null &&
      metadataIsEnglish(c.title, c.description);

  Future<String> _evaluate(CandidateVideo c, _Target t, Future<VideoDetails> Function(CandidateVideo) detailsFor,
      {List<String> context = const [], bool allowSpeech = true}) async {
    // Format pre-filter (Path B wants shorts; no point classifying long videos).
    if (t.path == IngestPath.theoremPool && (c.durationSec == null || c.durationSec! > shortMaxSeconds)) {
      return _log(c.id, 'rejected_format', 'not short-form (${c.durationSec}s)', t.id);
    }

    // Cheap local gates first.
    final kw = unsafeKeyword('${c.title}\n${c.description}');
    if (kw != null) {
      return _rejectVideo(c.id, 'rejected_safety', 'keyword: $kw', t,
          title: c.title, description: c.description, durationSec: c.durationSec, thumbnail: c.thumbnailUrl);
    }
    if (!metadataIsEnglish(c.title, c.description)) {
      return _rejectVideo(c.id, 'rejected_lang', 'title/description not English', t,
          title: c.title, description: c.description, durationSec: c.durationSec, thumbnail: c.thumbnailUrl);
    }

    final d = await detailsFor(c);
    String rejectV(String status, String reason) => _rejectVideo(c.id, status, reason, t,
        title: d.title, description: d.description, durationSec: d.durationSec, thumbnail: d.thumbnailUrl);

    final kw2 = unsafeKeyword('${d.title}\n${d.description}');
    if (kw2 != null) return rejectV('rejected_safety', 'keyword: $kw2');
    if (!metadataIsEnglish(d.title, d.description)) return rejectV('rejected_lang', 'title/description not English');

    // Gate 3: transcript language, or Whisper on the first 30 s when there's none.
    if (d.transcriptLines.isNotEmpty) {
      final lang = transcriptLanguage(d.transcriptLines);
      if (!lang.isEnglish) {
        return rejectV('rejected_lang',
            'transcript ${(lang.nonEnglishShare * 100).round()}% non-English (${lang.nonEnglish}/${lang.chunks})');
      }
    } else {
      if (!allowSpeech) return _deferred;
      final probe = _speech;
      if (probe == null) return rejectV('rejected_lang', 'no transcript and no speech probe available');
      final clip = await source.downloadAudioClip(c.id);
      final text = clip == null ? null : await probe.transcribeClip(clip);
      if (text == null || !speechIsEnglish(text)) return rejectV('rejected_lang', 'speech not verified as English');
    }

    // Gates 1 + 2. Decided by rule when the evidence is strong (instant):
    //  - a trusted educational channel that plainly covers the concept, or
    //  - the title names it, the captions say it, and the title/description reads
    //    as a lesson or the captions mention 2+ other concepts from your material.
    // Everything else gets one short on-device model call.
    final transcript = d.transcript;
    final names = [t.name, ...t.aliases];
    final covers = coversConcept(names, title: d.title, description: d.description, transcript: transcript);
    final channel = d.channel ?? c.channel;
    List<ConceptRef> mapped;
    bool isTheorem;
    String reason;
    final ruleTheorem = t.path == IngestPath.theoremPool || const {'theorem', 'formula'}.contains(t.type);
    if (isTrustedChannel(channel) && covers) {
      mapped = [ConceptRef(t.id, t.name, 100)];
      isTheorem = ruleTheorem;
      reason = 'trusted channel ($channel) covering ${t.name}';
    } else if (strongEvidence(names,
        title: d.title, description: d.description, transcript: transcript, materialConcepts: context)) {
      mapped = [ConceptRef(t.id, t.name, 95)];
      isTheorem = ruleTheorem;
      reason = 'title and captions teach ${t.name}';
    } else {
      final VideoVerdict v;
      try {
        v = await classifyVideo(
          model,
          searchedConcept: t.name,
          title: d.title,
          description: d.description,
          transcriptExcerpt: transcript,
          durationSec: d.durationSec,
          channel: channel,
        );
      } on ModelRefusal catch (e) {
        return rejectV('rejected_safety', 'model refusal (${e.category})');
      }
      if (!v.educational) return rejectV('rejected_edu', 'model: not educational');
      if (!v.safe) return rejectV('rejected_safety', 'model: unsafe');
      if (!v.english) return rejectV('rejected_lang', 'model: title/description not English');
      // A small model sometimes misses a plain match; if the video plainly covers
      // the concept by the rule above, count it.
      mapped = v.onTopic || covers ? [ConceptRef(t.id, t.name, v.onTopic ? 90 : 80)] : const [];
      isTheorem = v.isTheorem;
      reason = 'model: educational, on topic';
    }
    final subjectOut = t.subject;

    // Concept tagging + scope check.
    final isShort = (d.durationSec ?? 1 << 30) <= shortMaxSeconds && d.isVertical;
    switch (t.path) {
      case IngestPath.material:
        // Reject at ingestion if none of its primary concepts is active — keeps the library clean.
        if (!mapped.any((m) => isActiveConcept(m.id))) {
          return _log(c.id, 'rejected_scope', 'not mainly about ${t.name}', t.id);
        }
      case IngestPath.theoremPool:
        if (!mapped.any((m) => m.id == t.id)) {
          return _log(c.id, 'rejected_scope', 'not mainly about ${t.name}', t.id);
        }
        if (!isShort || !isTheorem) {
          return _log(c.id, 'rejected_format', 'pool needs a theorem short (short=$isShort theorem=$isTheorem)', t.id);
        }
    }

    // Accept. (Embeddings arrive with the on-device embedding model in Phase C/D.)
    final videoId = _uuid.v4();
    final subject = t.path == IngestPath.theoremPool ? 'math' : subjectOut;
    _db.transaction(() {
      _db.execute(
        'INSERT INTO videos (id, source, source_id, title, description, transcript, duration_sec, thumbnail_url, '
        'is_short, is_theorem, subject, in_theorem_pool, status, created_at) '
        "VALUES (?, 'youtube', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)",
        [videoId, c.id, d.title, d.description, transcript, d.durationSec, d.thumbnailUrl, boolInt(isShort),
         boolInt(isTheorem), subject, boolInt(t.path == IngestPath.theoremPool), nowMs()],
      );
      for (final m in mapped) {
        _db.execute('INSERT INTO video_concepts (video_id, concept_id, confidence, is_primary) VALUES (?, ?, ?, 1)',
            [videoId, m.id, (m.score.clamp(0, 100)) / 100]);
      }
      _log(c.id, 'accepted', reason, t.id);
    });
    return 'accepted';
  }
}
