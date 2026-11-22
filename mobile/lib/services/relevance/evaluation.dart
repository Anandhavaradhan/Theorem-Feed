/// Layer C: the relevance evaluation loop (§9.3), on the device.
///
/// Golden set: for a few concepts from your material, you mark videos as good
/// or bad examples (long-press a video on a concept page). The spec's set is
/// 5 concepts × 10 videos (5 good, 5 bad), hand-picked once.
///
/// Metrics are computed on what the long-form feed would actually show for each
/// concept (top 10, after the judge's ranking and off-topic filtering):
///
///   precision@10    = good shown / labelled shown   (target ≥ 0.7)
///   bad_video_rate  = bad shown / all shown          (target ≤ 0.1)
///
/// Both are averaged over the labelled concepts. Every change to retrieval
/// (§9.1) or the judge (§9.2) should be checked against this.
library;

import '../../data/app_database.dart';
import 'relevance_service.dart';

const precisionTarget = 0.7;
const badRateTarget = 0.1;
const goldenConceptsTarget = 5;
const goldenVideosPerConcept = 10;

enum GoldenLabel { good, bad }

class ConceptEval {
  ConceptEval({
    required this.conceptId,
    required this.name,
    required this.shown,
    required this.goodShown,
    required this.badShown,
    required this.goodLabels,
    required this.badLabels,
  });

  final String conceptId;
  final String name;
  final int shown;
  final int goodShown;
  final int badShown;
  final int goodLabels;
  final int badLabels;

  double? get precision => goodShown + badShown == 0 ? null : goodShown / (goodShown + badShown);
  double? get badRate => shown == 0 ? null : badShown / shown;
}

class EvalReport {
  EvalReport(this.concepts);
  final List<ConceptEval> concepts;

  double? _mean(Iterable<double?> xs) {
    final v = xs.whereType<double>().toList();
    return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
  }

  double? get precisionAt10 => _mean(concepts.map((c) => c.precision));
  double? get badRateAt10 => _mean(concepts.map((c) => c.badRate));
  bool get passes =>
      precisionAt10 != null && badRateAt10 != null && precisionAt10! >= precisionTarget && badRateAt10! <= badRateTarget;
}

class GoldenProgress {
  GoldenProgress(this.concepts, this.videos);
  final int concepts; // concepts with at least one good and one bad label
  final int videos; // labelled videos in total
}

class EvaluationService {
  EvaluationService(this._db);
  final AppDatabase _db;

  void setLabel(String conceptId, String videoId, GoldenLabel? label) {
    if (label == null) {
      _db.execute('DELETE FROM golden_labels WHERE concept_id = ? AND video_id = ?', [conceptId, videoId]);
    } else {
      _db.execute(
        'INSERT OR REPLACE INTO golden_labels (concept_id, video_id, label, created_at) VALUES (?, ?, ?, ?)',
        [conceptId, videoId, label.name, nowMs()],
      );
    }
  }

  GoldenLabel? labelOf(String conceptId, String videoId) {
    final r = _db.select('SELECT label FROM golden_labels WHERE concept_id = ? AND video_id = ?', [conceptId, videoId]);
    return r.isEmpty ? null : GoldenLabel.values.byName(r.first['label'] as String);
  }

  /// Concepts with both good and bad labels, still in your active material.
  List<String> labelledConcepts() => [
        for (final r in _db.select('''
          SELECT g.concept_id FROM golden_labels g JOIN user_active_concepts u ON u.concept_id = g.concept_id
          GROUP BY g.concept_id
          HAVING sum(g.label = 'good') > 0 AND sum(g.label = 'bad') > 0
          ORDER BY g.concept_id'''))
          r['concept_id'] as String,
      ];

  GoldenProgress progress() => GoldenProgress(
        labelledConcepts().length,
        _db.select('SELECT count(*) AS n FROM golden_labels').first['n'] as int,
      );

  /// Computes the metrics from cached judgements (run RelevanceService.rankConcept
  /// on [labelledConcepts] first so every labelled video is judged).
  EvalReport evaluate(RelevanceService relevance) {
    final out = <ConceptEval>[];
    for (final id in labelledConcepts()) {
      final labels = {
        for (final r in _db.select('SELECT video_id, label FROM golden_labels WHERE concept_id = ?', [id]))
          r['video_id'] as String: r['label'] as String,
      };
      final shown = relevance.rankedFor(id, limit: 10).map((v) => v.videoId).toList();
      final name = _db.select('SELECT canonical_name FROM concepts WHERE id = ?', [id]).first['canonical_name'] as String;
      out.add(ConceptEval(
        conceptId: id,
        name: name,
        shown: shown.length,
        goodShown: shown.where((v) => labels[v] == 'good').length,
        badShown: shown.where((v) => labels[v] == 'bad').length,
        goodLabels: labels.values.where((l) => l == 'good').length,
        badLabels: labels.values.where((l) => l == 'bad').length,
      ));
    }
    return EvalReport(out);
  }
}
