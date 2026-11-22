/// The relevance engine (§9): retrieve → judge → score → cache; feeds and
/// search consume the cached scores.
///
/// Caching (§9.4): a (video, concept) pair is judged once and stored in
/// relevance_scores; only cache misses reach the model. Feed rankings are
/// computed from the cache on every read, so material changes apply at once.
library;

import '../../data/app_database.dart';
import '../llm.dart';
import 'judge.dart';
import 'retrieval.dart';

/// Topic fit at or above this confirms a statement- or graph-retrieved video as
/// primarily about the concept (it then appears in the feed for it).
const confirmTopicFit = 7.0;

/// Topic fit at or below this means "clearly about something else": hidden from
/// the feed for that concept.
const offTopicFit = 2.0;

class RankReport {
  int concepts = 0;
  int judged = 0;
  int confirmed = 0;
  int errors = 0;
}

class RankedVideo {
  RankedVideo(this.videoId, this.title, this.finalScore, this.reason);
  final String videoId;
  final String title;
  final double? finalScore;
  final String? reason;
}

class RelevanceService {
  RelevanceService(this._db, this.model, {this.maxJudged = 12, this.topK = 50});

  final AppDatabase _db;
  final JsonModel model;

  /// Spec: "top ~20 candidates". 12 keeps on-device judging to three short calls per concept.
  final int maxJudged;
  final int topK;

  bool _cached(String videoId, String conceptId) =>
      _db.select('SELECT 1 FROM relevance_scores WHERE video_id = ? AND concept_id = ?', [videoId, conceptId]).isNotEmpty;

  /// Judges the concept's top candidates that aren't cached yet.
  Future<RankReport> rankConcept(String conceptId, {RankReport? into}) async {
    final report = into ?? RankReport();
    final ctx = conceptContext(_db, conceptId);
    if (ctx == null) return report;
    report.concepts++;
    final candidates = retrieveCandidates(_db, ctx, topK: topK).take(maxJudged).toList();
    final todo = candidates.where((c) => !_cached(c.videoId, conceptId)).toList();
    final active = _db.select('SELECT 1 FROM user_active_concepts WHERE concept_id = ?', [conceptId]).isNotEmpty;

    for (var i = 0; i < todo.length; i += judgeBatchSize) {
      final batch = todo.sublist(i, i + judgeBatchSize > todo.length ? todo.length : i + judgeBatchSize);
      List<Judgement> judged;
      try {
        judged = await judgeBatch(model, ctx, batch);
      } on ModelApiError {
        report.errors++;
        continue;
      } on ModelRefusal {
        report.errors++;
        continue;
      }
      _db.transaction(() {
        for (final j in judged) {
          _db.execute(
            'INSERT OR REPLACE INTO relevance_scores (video_id, concept_id, topic_fit, level_fit, depth_fit, '
            'prerequisite_ok, final, reason, judged_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [j.videoId, conceptId, j.topicFit, j.levelFit, j.depthFit, j.prerequisiteOk, j.finalScore, j.reason, nowMs()],
          );
          report.judged++;
          // A retrieved-but-untagged video the judge confirms becomes tagged to the
          // concept, so the feed (which only shows tagged, in-scope videos) can use it.
          if (active && j.topicFit >= confirmTopicFit) {
            final existing = _db.select(
                'SELECT is_primary FROM video_concepts WHERE video_id = ? AND concept_id = ?', [j.videoId, conceptId]);
            if (existing.isEmpty || existing.first['is_primary'] != 1) {
              _db.execute(
                'INSERT OR REPLACE INTO video_concepts (video_id, concept_id, confidence, is_primary) VALUES (?, ?, ?, 1)',
                [j.videoId, conceptId, j.finalScore],
              );
              report.confirmed++;
            }
          }
        }
      });
    }
    return report;
  }

  /// Ranks every active concept that has unjudged candidates, highest priority first.
  Future<RankReport> rankActiveConcepts({void Function(String concept, RankReport r)? onProgress, bool Function()? isCancelled}) async {
    final report = RankReport();
    for (final r in _db.select('''
      SELECT u.concept_id, c.canonical_name FROM user_active_concepts u JOIN concepts c ON c.id = u.concept_id
      ORDER BY u.priority DESC''')) {
      if (isCancelled?.call() ?? false) break;
      onProgress?.call(r['canonical_name'] as String, report);
      await rankConcept(r['concept_id'] as String, into: report);
    }
    return report;
  }

  /// What the long-form feed would show for one concept, best first (top [limit]):
  /// in-scope primary-tagged videos, judged clearly off-topic ones hidden.
  List<RankedVideo> rankedFor(String conceptId, {int limit = 10}) => [
        for (final r in _db.select('''
          SELECT v.id, v.title, rs.final, rs.reason FROM videos v
          JOIN video_concepts vc ON vc.video_id = v.id AND vc.is_primary = 1 AND vc.concept_id = ?
          JOIN user_active_concepts u ON u.concept_id = vc.concept_id
          LEFT JOIN relevance_scores rs ON rs.video_id = v.id AND rs.concept_id = vc.concept_id
          WHERE v.status = 'active' AND v.is_short = 0 AND (rs.topic_fit IS NULL OR rs.topic_fit > ?)
          ORDER BY rs.final IS NULL, rs.final DESC, v.created_at
          LIMIT ?''', [conceptId, offTopicFit, limit]))
          RankedVideo(r['id'] as String, r['title'] as String, (r['final'] as num?)?.toDouble(), r['reason'] as String?),
      ];
}
