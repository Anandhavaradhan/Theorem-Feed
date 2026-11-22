/// Feeds (§10). The scope predicates are the core of the app:
///
///   long-form: status='active' AND is_short=0 AND primary_concept ∈ user_active_concepts
///   shorts:    status='active' AND is_short=1 AND
///              ((in_theorem_pool AND subject='math') OR primary_concept ∈ user_active_concepts)
///
/// There is no fallback and no padding with other topics. An empty long-form
/// feed is the upload empty state or coverage-gap cards.
library;

import '../data/app_database.dart';
import '../models/feed.dart';

const longformPerConceptCap = 3;
const shortsMaterialShare = 0.65;

class FeedRow {
  FeedRow({
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.durationSec,
    required this.isShort,
    required this.conceptId,
    required this.conceptName,
    required this.priority,
    required this.finalScore,
    required this.fromMaterial,
    this.order = 0,
  });

  final String videoId;
  final String title;
  final String? thumbnailUrl;
  final int? durationSec;
  final bool isShort;
  final String conceptId;
  final String conceptName;
  final double priority; // concept priority (0 for theorem-pool-only)
  final double? finalScore; // cached LLM-judge score
  final bool fromMaterial;
  final int order; // curated pool order

  /// relevance_scores.final desc; cold start falls back to concept priority (§10.4).
  int compareTo(FeedRow o) {
    final a = (finalScore != null ? 1 : 0).compareTo(o.finalScore != null ? 1 : 0);
    if (a != 0) return -a;
    final b = (finalScore ?? 0).compareTo(o.finalScore ?? 0);
    if (b != 0) return -b;
    return -priority.compareTo(o.priority);
  }

  FeedCard toCard() => FeedCard(
        videoId: videoId,
        title: title,
        thumbnailUrl: thumbnailUrl,
        durationSec: durationSec,
        isShort: isShort,
        conceptId: conceptId,
        conceptName: conceptName,
        fromMaterial: fromMaterial,
        score: finalScore,
      );
}

class FeedService {
  FeedService(this._db);
  final AppDatabase _db;

  bool hasActiveMaterial() => _db.select('SELECT 1 FROM user_active_concepts LIMIT 1').isNotEmpty;

  List<FeedRow> _materialRows({required bool isShort}) => [
        for (final r in _db.select('''
          SELECT v.id, v.title, v.thumbnail_url, v.duration_sec, v.is_short,
                 c.id AS concept_id, c.canonical_name, uac.priority, rs.final
          FROM videos v
          JOIN video_concepts vc ON vc.video_id = v.id AND vc.is_primary = 1
          JOIN user_active_concepts uac ON uac.concept_id = vc.concept_id
          JOIN concepts c ON c.id = vc.concept_id
          LEFT JOIN relevance_scores rs ON rs.video_id = v.id AND rs.concept_id = vc.concept_id
          WHERE v.status = 'active' AND v.is_short = ?
        ''', [boolInt(isShort)]))
          FeedRow(
            videoId: r['id'] as String,
            title: r['title'] as String,
            thumbnailUrl: r['thumbnail_url'] as String?,
            durationSec: r['duration_sec'] as int?,
            isShort: r['is_short'] == 1,
            conceptId: r['concept_id'] as String,
            conceptName: r['canonical_name'] as String,
            priority: (r['priority'] as num).toDouble(),
            finalScore: (r['final'] as num?)?.toDouble(),
            fromMaterial: true,
          ),
      ];

  List<FeedRow> _theoremPoolRows() => [
        for (final r in _db.select('''
          SELECT v.id, v.title, v.thumbnail_url, v.duration_sec,
                 c.id AS concept_id, c.canonical_name, c.pool_order, rs.final
          FROM videos v
          JOIN video_concepts vc ON vc.video_id = v.id AND vc.is_primary = 1
          JOIN concepts c ON c.id = vc.concept_id
          LEFT JOIN relevance_scores rs ON rs.video_id = v.id AND rs.concept_id = vc.concept_id
          WHERE v.status = 'active' AND v.is_short = 1 AND v.in_theorem_pool = 1 AND v.subject = 'math'
          ORDER BY coalesce(c.pool_order, 1e9), v.created_at
        '''))
          FeedRow(
            videoId: r['id'] as String,
            title: r['title'] as String,
            thumbnailUrl: r['thumbnail_url'] as String?,
            durationSec: r['duration_sec'] as int?,
            isShort: true,
            conceptId: r['concept_id'] as String,
            conceptName: r['canonical_name'] as String,
            priority: 0,
            finalScore: (r['final'] as num?)?.toDouble(),
            fromMaterial: false,
            order: (r['pool_order'] as int?) ?? 1 << 30,
          ),
      ];

  /// Active concepts with no active long-form primary video.
  List<CoverageGap> coverageGaps() => [
        for (final r in _db.select('''
          SELECT c.id, c.canonical_name FROM concepts c
          JOIN user_active_concepts uac ON uac.concept_id = c.id
          WHERE NOT EXISTS (
            SELECT 1 FROM video_concepts vc JOIN videos v ON v.id = vc.video_id
            WHERE vc.concept_id = c.id AND vc.is_primary = 1 AND v.status = 'active' AND v.is_short = 0
          )
          ORDER BY uac.priority DESC, c.canonical_name COLLATE NOCASE
        '''))
          CoverageGap(conceptId: r['id'] as String, concept: r['canonical_name'] as String),
      ];

  FeedResponse longform({int limit = 30}) {
    if (!hasActiveMaterial()) return FeedResponse(items: const [], needsUpload: true);
    final rows = capPerConcept(bestPerVideo(_materialRows(isShort: false)), longformPerConceptCap, limit);
    return FeedResponse(
      items: rows.take(limit).map((r) => r.toCard()).toList(),
      coverageGaps: coverageGaps(),
    );
  }

  FeedResponse shorts({int limit = 30}) {
    var pool = _theoremPoolRows();
    if (!hasActiveMaterial()) {
      // Cold start: 100% theorem pool, curated order.
      return FeedResponse(items: interleave(const [], pool, 0).take(limit).map((r) => r.toCard()).toList());
    }
    final material = bestPerVideo(_materialRows(isShort: true));
    final materialIds = {for (final r in material) r.videoId};
    pool = pool.where((r) => !materialIds.contains(r.videoId)).toList()
      ..sort((a, b) {
        final c = a.compareTo(b);
        return c != 0 ? c : a.order.compareTo(b.order);
      });
    return FeedResponse(
      items: interleave(material, pool, shortsMaterialShare).take(limit).map((r) => r.toCard()).toList(),
    );
  }
}

/// A video can be primary for several active concepts; keep its strongest pairing.
List<FeedRow> bestPerVideo(List<FeedRow> rows) {
  final best = <String, FeedRow>{};
  for (final r in rows) {
    final cur = best[r.videoId];
    if (cur == null || r.compareTo(cur) < 0) best[r.videoId] = r;
  }
  return best.values.toList()..sort((a, b) => a.compareTo(b));
}

/// At most [cap] videos per concept in the first [window] items; overflow follows after.
List<FeedRow> capPerConcept(List<FeedRow> rows, int cap, int window) {
  final head = <FeedRow>[];
  final overflow = <FeedRow>[];
  final counts = <String, int>{};
  for (final r in rows) {
    final n = counts[r.conceptId] ?? 0;
    if (head.length < window && n < cap) {
      head.add(r);
      counts[r.conceptId] = n + 1;
    } else {
      overflow.add(r);
    }
  }
  return [...head, ...overflow];
}

/// Blends two ranked queues at ~[share] material, avoiding the same concept back-to-back.
List<FeedRow> interleave(List<FeedRow> material, List<FeedRow> pool, double share) {
  final out = <FeedRow>[];
  final m = [...material];
  final p = [...pool];
  var nMaterial = 0;
  while (m.isNotEmpty || p.isNotEmpty) {
    final wantMaterial = m.isNotEmpty && (p.isEmpty || nMaterial < share * (out.length + 1));
    final queue = wantMaterial ? m : p;
    final last = out.isEmpty ? null : out.last.conceptId;
    var idx = queue.indexWhere((r) => r.conceptId != last);
    if (idx < 0) idx = 0;
    out.add(queue.removeAt(idx));
    if (wantMaterial) nMaterial++;
  }
  return out;
}
