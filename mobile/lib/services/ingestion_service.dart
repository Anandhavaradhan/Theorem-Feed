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
import 'text_match.dart';
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

/// Thrown inside a run when Stop was pressed; the run returns what it has.
class _Stopped implements Exception {
  const _Stopped();
}

class IngestReport {
  int checked = 0;
  int accepted = 0;
  int acceptedShorts = 0;

  /// Candidates not seen before (0 for a whole round: YouTube has nothing new).
  int fresh = 0;
  final Map<String, int> rejected = {};
  final List<String> errors = [];
  void reject(String outcome) => rejected[outcome] = (rejected[outcome] ?? 0) + 1;
  @override
  String toString() => 'checked=$checked accepted=$accepted rejected=$rejected errors=${errors.length}';
}

typedef IngestProgress = void Function(String conceptName, IngestReport report);

class _Target {
  _Target(this.id, this.name, this.aliases, this.subject, this.type, this.path,
      {this.contextWords = const [], this.notesLabel});
  final String id;
  final String name;
  final List<String> aliases;
  final String subject;
  final String type;
  final IngestPath path;

  /// Words from the chapter/section the concept sits in ("standing waves" for
  /// Superposition), so the search and the checks use it in your notes' sense.
  final List<String> contextWords;

  /// "Sound notes › Superposition and standing waves", for the AI check.
  final String? notesLabel;
}

const _contextStopwords = {
  'a', 'an', 'the', 'of', 'and', 'or', 'in', 'on', 'to', 'for', 'with', 'by', 'its', 'their', 'is', 'are', 'what',
  'how', 'why', 'introduction', 'intro', 'basics', 'basic', 'part', 'chapter', 'section', 'unit', 'notes', 'more',
  'two', 'three', 'kinds', 'types', 'uses', 'about',
};

class IngestionService {
  IngestionService({
    required this._db,
    required this.source,
    required this.model,
    SpeechLanguageProbe? speechProbe,
    this.candidatesPerConcept = 8,
    this.acceptPerConcept = 3,
    this.prefetchAhead = 3,
    this.isCancelled,
  }) : _speech = speechProbe;

  /// Stop: checked before each video, each download wait and each AI call.
  final bool Function()? isCancelled;
  bool get _stopped => isCancelled?.call() ?? false;

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
    final name = r['canonical_name'] as String;
    var words = <String>[];
    String? label;
    if (path == IngestPath.material) {
      final where = _db.select('''
        SELECT m.title, mc.chapter, mc.section FROM material_concepts mc JOIN materials m ON m.id = mc.material_id
        WHERE mc.concept_id = ? AND m.status = 'active' ORDER BY mc.importance DESC LIMIT 1''', [conceptId]).firstOrNull;
      if (where != null) {
        String strip(String? h) => (h ?? '').replaceFirst(RegExp(r'^\s*(chapter\s+)?\d+(\.\d+)*\.?\s*', caseSensitive: false), '');
        final chapter = strip(where['chapter'] as String?);
        final section = strip(where['section'] as String?);
        final nameWords = normalizeText(name).split(' ').toSet();
        final seen = <String>{};
        for (final w in normalizeText('$section $chapter').split(' ')) {
          if (w.length < 3 || _contextStopwords.contains(w) || nameWords.contains(w) || !seen.add(w)) continue;
          words.add(w);
        }
        words = words.take(2).toList();
        label = [where['title'] as String, if (chapter.isNotEmpty) chapter, if (section.isNotEmpty && section != chapter) section]
            .join(' › ');
      }
    }
    return _Target(conceptId, name, parseJsonList(r['aliases'] as String?), r['subject'] as String, r['type'] as String,
        path,
        contextWords: words, notesLabel: label);
  }

  // --- public entry points ----------------------------------------------------

  /// Path A for one concept (coverage-gap "Find videos", concept detail, and —
  /// from Phase C — automatically after a material upload).
  Future<IngestReport> ingestMaterialConcept(String conceptId, {IngestProgress? onProgress}) =>
      _ingest(_target(conceptId, IngestPath.material), IngestReport(), onProgress);

  // --- keep filling: long videos and shorts, round after round ---------------

  /// Per concept, the library grows to this many long videos and shorts.
  static const maxPerKind = 20;

  /// Each round raises the target by this much for both kinds.
  static const perRound = 3;

  /// Rounds after which every concept has had its chance at [maxPerKind].
  static int get maxRounds => (maxPerKind / perRound).ceil();

  /// Each round words the search differently, so YouTube returns new videos.
  static const longVariants = ['', 'explained', 'examples', 'problems solved', 'lecture', 'animation', 'tutorial'];
  static const shortVariants = [
    '#shorts', 'explained #shorts', 'in 60 seconds', 'trick #shorts', 'animation #shorts', 'example #shorts',
    'shorts',
  ];

  /// Active long videos and shorts whose primary concept is [conceptId].
  ({int long, int short}) videoCounts(String conceptId) {
    final r = _db.select('''
      SELECT coalesce(sum(v.is_short = 0), 0) AS l, coalesce(sum(v.is_short = 1), 0) AS s FROM videos v
      JOIN video_concepts vc ON vc.video_id = v.id AND vc.is_primary = 1
      WHERE vc.concept_id = ? AND v.status = 'active' ''', [conceptId]).first;
    return (long: (r['l'] as num).toInt(), short: (r['s'] as num).toInt());
  }

  /// Your concepts that have fewer than [target] long videos or shorts, most
  /// important first.
  List<String> conceptsBelow(int target) => [
        for (final r in _db.select('SELECT concept_id FROM user_active_concepts ORDER BY priority DESC'))
          if (videoCounts(r['concept_id'] as String) case final c when c.long < target || c.short < target)
            r['concept_id'] as String,
      ];

  /// One round for one concept of your notes: tops up long videos and shorts to
  /// [target] each (capped at [maxPerKind]), with round [round]'s wording.
  Future<IngestReport> fillConcept(String conceptId,
      {required int round, IngestProgress? onProgress, IngestReport? into}) async {
    final t = _target(conceptId, IngestPath.material);
    final report = into ?? IngestReport();
    final target = (perRound * round).clamp(perRound, maxPerKind);
    var c = videoCounts(conceptId);
    if (c.long < target) {
      await _ingest(t, report, onProgress,
          variant: longVariants[(round - 1) % longVariants.length], wantShort: false, need: target - c.long);
    }
    c = videoCounts(conceptId);
    if (c.short < target && !_stopped) {
      await _ingest(t, report, onProgress,
          variant: shortVariants[(round - 1) % shortVariants.length], wantShort: true, need: target - c.short);
    }
    return report;
  }

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
      if ((isCancelled?.call() ?? false) || _stopped) break;
      await _ingest(_target(row['id'] as String, IngestPath.theoremPool), report, onProgress);
    }
    return report;
  }

  // --- pipeline ---------------------------------------------------------------

  static const _subjectWord = {'physics': 'physics', 'math': 'math', 'cs': 'computer science'};

  /// The YouTube query. A short name ("Echo", "Phase", "Pitch") also matches
  /// songs, brands and games, so its subject is added ("Echo physics").
  String _query(_Target t, {String variant = ''}) {
    final alias = t.aliases.where((a) => !t.name.toLowerCase().contains(a.toLowerCase())).firstOrNull;
    var base = alias == null ? t.name : '${t.name} $alias';
    // "Superposition standing waves": the chapter keeps the search in your notes' sense.
    if (t.contextWords.isNotEmpty) base = '$base ${t.contextWords.join(' ')}';
    final subject = _subjectWord[t.subject];
    if (t.path == IngestPath.material &&
        subject != null &&
        alias == null &&
        t.name.split(' ').length <= 2 &&
        !base.toLowerCase().contains(subject)) {
      base = '$base $subject';
    }
    if (t.path == IngestPath.theoremPool) return '$base #shorts';
    return variant.isEmpty ? base : '$base $variant';
  }

  final _searches = <String, Future<List<CandidateVideo>>>{};

  Future<List<CandidateVideo>> _search(String query) => _searches.putIfAbsent(query, () {
        final f = source.search(query, limit: candidatesPerConcept);
        f.then((_) {}, onError: (_) {}); // surfaced when awaited
        return f;
      });

  /// Starts the YouTube search for a concept that will be checked next, so it
  /// is ready when the current concept finishes.
  void warmUp(String conceptId) {
    if (!canIngest(conceptId)) return;
    _search(_query(_target(conceptId, isActiveConcept(conceptId) ? IngestPath.material : IngestPath.theoremPool)));
  }

  Set<String>? _vocab;

  /// Every word of your active notes' concept names and statements: a word
  /// qualifying the concept in a title ("Quantum superposition") that your
  /// notes never use means another sense of it.
  Set<String> _vocabulary() => _vocab ??= {
        for (final r in _db.select('''
          SELECT c.canonical_name, mc.statement, mc.chapter, mc.section FROM material_concepts mc
          JOIN materials m ON m.id = mc.material_id JOIN concepts c ON c.id = mc.concept_id
          WHERE m.status = 'active' '''))
          for (final w in normalizeText(
                  '${r['canonical_name']} ${r['statement'] ?? ''} ${r['chapter'] ?? ''} ${r['section'] ?? ''}')
              .split(' '))
            if (w.length >= 3) ...{w, if (w.endsWith('s') && !w.endsWith('ss')) w.substring(0, w.length - 1)},
      };

  /// Names of the other concepts in your active material (context for the rule check).
  List<String> _materialNames(String exceptId) => [
        for (final r in _db.select('''
          SELECT c.canonical_name FROM user_active_concepts u JOIN concepts c ON c.id = u.concept_id
          WHERE c.id != ? ORDER BY u.priority DESC LIMIT 200''', [exceptId]))
          r['canonical_name'] as String,
      ];

  /// [wantShort]: null = any video counts towards [need] (default
  /// [acceptPerConcept]); true = only shorts count (long results are skipped
  /// unchecked, so the long-video search can still use them); false = only
  /// long videos count.
  Future<IngestReport> _ingest(_Target t, IngestReport report, IngestProgress? onProgress,
      {String variant = '', bool? wantShort, int? need}) async {
    if (_stopped) return report;
    onProgress?.call(t.name, report);
    final query = wantShort == true && t.path == IngestPath.material
        ? _query(t, variant: variant.isEmpty ? '#shorts' : variant)
        : _query(t, variant: variant);
    final wanted = need ?? acceptPerConcept;
    List<CandidateVideo> candidates;
    try {
      candidates = await _search(query);
    } catch (e) {
      _searches.remove(query);
      report.errors.add('search "${t.name}": $e');
      return report;
    }
    _searches.remove(query); // a later run searches afresh
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
    final todo = [
      for (final c in candidates)
        if (!_alreadySeen(c.id) && !(wantShort == true && (c.durationSec ?? 0) > shortMaxSeconds)) c,
    ];
    report.fresh += todo.length;
    // Videos without captions need the speech model, the slowest check by far;
    // they wait until the captioned ones have had their turn.
    final noCaptions = <CandidateVideo>[];

    Future<void> check(CandidateVideo c, {required bool allowSpeech}) async {
      String outcome;
      try {
        outcome = await _evaluate(c, t, detailsFor, context: context, allowSpeech: allowSpeech);
      } on _Stopped {
        rethrow;
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
        final short = _db.select('SELECT is_short FROM videos WHERE source_id = ?', [c.id]).firstOrNull?['is_short'] == 1;
        if (short) report.acceptedShorts++;
        if (wantShort == null || wantShort == short) acceptedHere++;
      } else if (outcome != 'error') {
        report.reject(outcome);
      }
      onProgress?.call(t.name, report);
    }

    try {
      for (var i = 0; i < todo.length; i++) {
        if (acceptedHere >= wanted || _stopped) break;
        for (final next in todo.skip(i).take(prefetchAhead + 1)) {
          if (_passesCheapChecks(next, t)) detailsFor(next);
        }
        await check(todo[i], allowSpeech: false);
      }
      for (final c in List.of(noCaptions)) {
        if (acceptedHere >= wanted || _stopped) break;
        await check(c, allowSpeech: true);
      }
    } on _Stopped {
      // Nothing is logged for the video being checked: it is checked again on Continue.
    }
    return report;
  }

  static const _deferred = '_deferred';

  /// Removes videos already in the library that the English-only rules now
  /// reject: first from what's stored (title, description, captions — instant,
  /// offline), then by asking YouTube which language is spoken (once per video;
  /// [checked] remembers which were done). Returns how many were removed.
  Future<int> recheckLanguages({required Set<String> checked, void Function(String youtubeId)? onChecked}) async {
    var removed = 0;
    void remove(String id, String youtubeId, String reason) {
      _db.execute("UPDATE videos SET status = 'rejected_lang' WHERE id = ?", [id]);
      _db.execute(
        'INSERT OR REPLACE INTO ingest_log (source_id, outcome, reason, concept_id, checked_at) VALUES (?, ?, ?, NULL, ?)',
        [youtubeId, 'rejected_lang', 'recheck: $reason', nowMs()],
      );
      removed++;
    }

    final rows = _db.select("SELECT id, source_id, title, description, transcript FROM videos WHERE status = 'active'");
    final remaining = <Map<String, Object?>>[];
    for (final r in rows) {
      final title = r['title'] as String? ?? '';
      final desc = r['description'] as String? ?? '';
      final lines = (r['transcript'] as String? ?? '').split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (!metadataIsEnglish(title, desc)) {
        remove(r['id'] as String, r['source_id'] as String, 'title/description not English');
      } else if (lines.isNotEmpty && !transcriptLanguage(lines).isEnglish) {
        remove(r['id'] as String, r['source_id'] as String, 'captions not English');
      } else {
        remaining.add(r);
      }
    }
    for (final r in remaining) {
      final yt = r['source_id'] as String;
      if (checked.contains(yt)) continue;
      if (_stopped) break;
      try {
        final d = await source.details(yt, needVertical: false);
        if (d.channel != null) {
          _db.execute('UPDATE videos SET channel = ? WHERE id = ? AND channel IS NULL', [d.channel, r['id']]);
        }
        final spoken = d.spokenLanguage;
        if (spoken != null && !spoken.toLowerCase().startsWith('en')) remove(r['id'] as String, yt, 'spoken language: $spoken');
        onChecked?.call(yt);
      } catch (_) {
        // offline or unavailable: tried again next time
      }
    }
    return removed;
  }

  /// Removes library videos whose title qualifies their concept with a word your
  /// notes never use ("Quantum superposition" for notes on sound waves). Offline
  /// and instant. Returns how many were removed.
  int recheckTopics() {
    final vocab = _vocabulary();
    if (vocab.isEmpty) return 0;
    var removed = 0;
    for (final r in _db.select('''
      SELECT v.id, v.source_id, v.title, c.id AS concept_id, c.canonical_name, c.aliases FROM videos v
      JOIN video_concepts vc ON vc.video_id = v.id AND vc.is_primary = 1
      JOIN user_active_concepts u ON u.concept_id = vc.concept_id
      JOIN concepts c ON c.id = vc.concept_id
      WHERE v.status = 'active' AND v.in_theorem_pool = 0''')) {
      final names = [r['canonical_name'] as String, ...parseJsonList(r['aliases'] as String?)];
      final q = foreignQualifier(names, r['title'] as String, vocab);
      if (q == null) continue;
      // Unlinked from the concept: it leaves every feed, and the log keeps it from coming back.
      _db.execute('DELETE FROM video_concepts WHERE video_id = ? AND concept_id = ?', [r['id'], r['concept_id']]);
      _db.execute(
        'INSERT OR REPLACE INTO ingest_log (source_id, outcome, reason, concept_id, checked_at) VALUES (?, ?, ?, ?, ?)',
        [r['source_id'], 'rejected_scope', 'recheck: "$q ${r['canonical_name']}" is another sense', r['concept_id'],
         nowMs()],
      );
      removed++;
    }
    return removed;
  }

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
    if (_stopped) throw const _Stopped();
    String rejectV(String status, String reason) => _rejectVideo(c.id, status, reason, t,
        title: d.title, description: d.description, durationSec: d.durationSec, thumbnail: d.thumbnailUrl);

    final kw2 = unsafeKeyword('${d.title}\n${d.description}');
    if (kw2 != null) return rejectV('rejected_safety', 'keyword: $kw2');
    if (!metadataIsEnglish(d.title, d.description)) return rejectV('rejected_lang', 'title/description not English');

    // Gate 3, English only:
    //  - the spoken language YouTube heard must be English (English subtitles on a
    //    video spoken in another language don't count);
    //  - the captions must read as English (not another language, not Hindi or
    //    Tamil written in English letters);
    //  - with no speech track, the first 30 s are checked on the device (slow, so last).
    final spoken = d.spokenLanguage;
    if (spoken != null && !spoken.toLowerCase().startsWith('en')) {
      return rejectV('rejected_lang', 'spoken language: $spoken');
    }
    if (d.transcriptLines.isNotEmpty) {
      final lang = transcriptLanguage(d.transcriptLines);
      if (!lang.isEnglish) {
        return rejectV('rejected_lang',
            'transcript ${(lang.nonEnglishShare * 100).round()}% non-English (${lang.nonEnglish}/${lang.chunks})');
      }
    }
    if (spoken == null) {
      if (!allowSpeech) return _deferred;
      if (_stopped) throw const _Stopped();
      final probe = _speech;
      if (probe == null) return rejectV('rejected_lang', 'spoken language unknown and no speech probe available');
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
        title: d.title,
        description: d.description,
        transcript: transcript,
        materialConcepts: t.path == IngestPath.material ? context : null,
        vocabulary: t.path == IngestPath.material ? _vocabulary() : null)) {
      mapped = [ConceptRef(t.id, t.name, 95)];
      isTheorem = ruleTheorem;
      reason = 'title and captions teach ${t.name}';
    } else {
      if (_stopped) throw const _Stopped();
      final VideoVerdict v;
      try {
        v = await classifyVideo(
          model,
          searchedConcept: t.name,
          notesContext: t.notesLabel,
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
      // ...but not when the title puts the concept in another sense ("Quantum superposition").
      final otherSense =
          t.path == IngestPath.material && foreignQualifier(names, d.title, _vocabulary()) != null;
      mapped = v.onTopic || (covers && !otherSense) ? [ConceptRef(t.id, t.name, v.onTopic ? 90 : 80)] : const [];
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
        'is_short, is_theorem, subject, in_theorem_pool, status, created_at, channel) '
        "VALUES (?, 'youtube', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)",
        [videoId, c.id, d.title, d.description, transcript, d.durationSec, d.thumbnailUrl, boolInt(isShort),
         boolInt(isTheorem), subject, boolInt(t.path == IngestPath.theoremPool), nowMs(), channel],
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
