/// Concept detail (§13.6) and small per-video helpers for the shorts overlay.
///
/// Videos listed for a concept obey the same scope predicate as the feeds:
/// long-form only while the concept is in your active material; shorts while
/// it's in your material or (for pool shorts) in the theorem pool.
library;

import '../data/app_database.dart';
import '../models/feed.dart';

class PrerequisiteNode {
  PrerequisiteNode({required this.id, required this.name, required this.depth, required this.inMaterial});
  final String id;
  final String name;
  final int depth; // 1 = direct prerequisite
  final bool inMaterial;
}

class ConceptDetail {
  ConceptDetail({
    required this.id,
    required this.name,
    required this.type,
    required this.subject,
    required this.statement,
    required this.latex,
    required this.difficulty,
    required this.chapter,
    required this.section,
    required this.inMaterial,
    required this.inTheoremPool,
    required this.prerequisites,
    required this.videos,
  });

  final String id;
  final String name;
  final String type;
  final String subject;
  final String statement; // how your material states it, else the graph description
  final String? latex;
  final String? difficulty;
  final String? chapter;
  final String? section;
  final bool inMaterial;
  final bool inTheoremPool; // math pool theorem
  final List<PrerequisiteNode> prerequisites;
  final List<FeedCard> videos;

  /// Scoped ingestion is allowed only for material concepts or pool theorems.
  bool get canFindVideos => inMaterial || inTheoremPool;
}

class ConceptService {
  ConceptService(this._db);
  final AppDatabase _db;

  ConceptDetail? detail(String conceptId, {int maxPrereqDepth = 3}) {
    final rows = _db.select('SELECT * FROM concepts WHERE id = ?', [conceptId]);
    if (rows.isEmpty) return null;
    final c = rows.first;
    final uac = _db.select('SELECT * FROM user_active_concepts WHERE concept_id = ?', [conceptId]).firstOrNull;
    final inMaterial = uac != null;
    final inPool = c['in_theorem_pool'] == 1 && c['subject'] == 'math';

    // Material framing: the highest-importance active material's row.
    final mc = _db.select('''
      SELECT mc.* FROM material_concepts mc JOIN materials m ON m.id = mc.material_id
      WHERE mc.concept_id = ? AND m.status = 'active' ORDER BY mc.importance DESC LIMIT 1
    ''', [conceptId]).firstOrNull;

    return ConceptDetail(
      id: conceptId,
      name: c['canonical_name'] as String,
      type: c['type'] as String,
      subject: c['subject'] as String,
      statement: (uac?['best_statement'] as String?) ?? (c['description'] as String),
      latex: (mc?['latex'] as String?) ?? (c['latex'] as String?),
      difficulty: uac?['best_difficulty'] as String?,
      chapter: mc?['chapter'] as String?,
      section: mc?['section'] as String?,
      inMaterial: inMaterial,
      inTheoremPool: inPool,
      prerequisites: prerequisiteChain(conceptId, maxDepth: maxPrereqDepth),
      videos: _videos(conceptId, c['canonical_name'] as String, inMaterial),
    );
  }

  /// Breadth-first over 'requires' edges, nearest first, each concept once.
  List<PrerequisiteNode> prerequisiteChain(String conceptId, {int maxDepth = 3}) {
    final out = <PrerequisiteNode>[];
    final seen = {conceptId};
    var frontier = [conceptId];
    for (var depth = 1; depth <= maxDepth && frontier.isNotEmpty; depth++) {
      final next = <String>[];
      for (final id in frontier) {
        for (final r in _db.select('''
          SELECT p.id, p.canonical_name, (uac.concept_id IS NOT NULL) AS active
          FROM concept_edges e JOIN concepts p ON p.id = e.to_concept
          LEFT JOIN user_active_concepts uac ON uac.concept_id = p.id
          WHERE e.from_concept = ? AND e.relation = 'requires'
          ORDER BY p.canonical_name
        ''', [id])) {
          final pid = r['id'] as String;
          if (!seen.add(pid)) continue;
          out.add(PrerequisiteNode(id: pid, name: r['canonical_name'] as String, depth: depth, inMaterial: r['active'] == 1));
          next.add(pid);
        }
      }
      frontier = next;
    }
    return out;
  }

  List<FeedCard> _videos(String conceptId, String name, bool inMaterial) => [
        for (final r in _db.select('''
          SELECT v.id, v.title, v.thumbnail_url, v.duration_sec, v.is_short, v.in_theorem_pool, v.subject
          FROM videos v JOIN video_concepts vc ON vc.video_id = v.id AND vc.is_primary = 1
          WHERE vc.concept_id = ? AND v.status = 'active'
          ORDER BY v.is_short, v.created_at
        ''', [conceptId]))
          if (inMaterial || (r['is_short'] == 1 && r['in_theorem_pool'] == 1 && r['subject'] == 'math'))
            FeedCard(
              videoId: r['id'] as String,
              title: r['title'] as String,
              thumbnailUrl: r['thumbnail_url'] as String?,
              durationSec: r['duration_sec'] as int?,
              isShort: r['is_short'] == 1,
              conceptId: conceptId,
              conceptName: name,
              fromMaterial: inMaterial,
            ),
      ];

  /// "Go deeper" target for a short: a long-form video for the same concept,
  /// only if that concept is in your material (§13.2).
  FeedCard? goDeeper(String conceptId) {
    final r = _db.select('''
      SELECT v.id, v.title, v.thumbnail_url, v.duration_sec, c.canonical_name
      FROM videos v
      JOIN video_concepts vc ON vc.video_id = v.id AND vc.is_primary = 1
      JOIN user_active_concepts uac ON uac.concept_id = vc.concept_id
      JOIN concepts c ON c.id = vc.concept_id
      LEFT JOIN relevance_scores rs ON rs.video_id = v.id AND rs.concept_id = vc.concept_id
      WHERE vc.concept_id = ? AND v.status = 'active' AND v.is_short = 0
      ORDER BY rs.final DESC NULLS LAST, v.created_at LIMIT 1
    ''', [conceptId]).firstOrNull;
    if (r == null) return null;
    return FeedCard(
      videoId: r['id'] as String,
      title: r['title'] as String,
      thumbnailUrl: r['thumbnail_url'] as String?,
      durationSec: r['duration_sec'] as int?,
      isShort: false,
      conceptId: conceptId,
      conceptName: r['canonical_name'] as String,
      fromMaterial: true,
    );
  }

  bool isSaved(String videoId) =>
      _db.select('SELECT 1 FROM watch_history WHERE video_id = ? AND saved = 1', [videoId]).isNotEmpty;

  /// Saving is a flag on the video's watch-history row (soft state, never deleted).
  bool toggleSaved(String videoId) {
    final row = _db.select('SELECT id, saved FROM watch_history WHERE video_id = ? ORDER BY created_at LIMIT 1', [videoId]);
    final saved = !(row.isNotEmpty && row.first['saved'] == 1);
    if (row.isEmpty) {
      _db.execute(
        'INSERT INTO watch_history (id, video_id, saved, created_at) VALUES (lower(hex(randomblob(16))), ?, ?, ?)',
        [videoId, boolInt(saved), nowMs()],
      );
    } else {
      _db.execute('UPDATE watch_history SET saved = ? WHERE id = ?', [boolInt(saved), row.first['id']]);
    }
    return saved;
  }

  /// Counts for the settings screen.
  Map<String, int> libraryStats() => {
        'pool_theorems':
            _db.select("SELECT count(*) AS n FROM concepts WHERE in_theorem_pool = 1 AND subject = 'math'").first['n'] as int,
        'pool_shorts': _db.select(
                "SELECT count(*) AS n FROM videos WHERE status = 'active' AND is_short = 1 AND in_theorem_pool = 1")
            .first['n'] as int,
        'material_videos': _db.select('''
          SELECT count(DISTINCT v.id) AS n FROM videos v JOIN video_concepts vc ON vc.video_id = v.id AND vc.is_primary = 1
          JOIN user_active_concepts u ON u.concept_id = vc.concept_id WHERE v.status = 'active' ''').first['n'] as int,
        'checked': _db.select('SELECT count(*) AS n FROM ingest_log').first['n'] as int,
        'accepted': _db.select("SELECT count(*) AS n FROM ingest_log WHERE outcome = 'accepted'").first['n'] as int,
      };
}
