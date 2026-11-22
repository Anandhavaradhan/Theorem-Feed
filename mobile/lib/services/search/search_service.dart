/// Search (§11): a five-stage pipeline, entirely on the device (so it also works offline).
///
///   1. Query understanding  empty / formula / concept (typo-tolerant) / natural
///   2. Scope resolution     BEFORE retrieval: the same universe as the feeds
///   3. Hybrid retrieval     concept tags + BM25 over title, description, transcript
///   4. Re-rank              concept match beats everything (tagged videos stay in the top 3)
///   5. Group                by concept, with reason labels, coverage-gap and out-of-scope cards
///
/// Never a silent empty: every miss returns a coverage-gap or out-of-scope card.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../data/app_database.dart';
import '../../models/feed.dart';
import '../concept_matcher.dart';
import '../relevance/relevance_service.dart' show offTopicFit;
import '../text_match.dart';

enum QueryIntent { empty, concept, formula, natural }

class QueryUnderstanding {
  QueryUnderstanding(this.intent, this.raw, {this.conceptId, this.conceptName, this.expandedTerms = const []});
  final QueryIntent intent; // formula queries that map to a concept become `concept` (viaFormula = true)
  final String raw;
  final String? conceptId;
  final String? conceptName;
  final List<String> expandedTerms;
  bool viaFormula = false;
}

enum GroupKind { material, theorem, prerequisiteGap, coverageGap }

class SearchGroup {
  SearchGroup({
    required this.conceptId,
    required this.conceptName,
    required this.kind,
    this.chapter,
    this.videos = const [],
  });

  final String conceptId;
  final String conceptName;
  final GroupKind kind;
  final String? chapter; // "from Chapter 7.2"
  final List<FeedCard> videos;

  bool get isGap => kind == GroupKind.prerequisiteGap || kind == GroupKind.coverageGap;

  /// Reason label for the group (constraint #14).
  String get reasonLabel => switch (kind) {
        GroupKind.material => 'From your material: $conceptName',
        GroupKind.theorem => 'Math theorem: $conceptName',
        GroupKind.prerequisiteGap => 'Prerequisite: $conceptName',
        GroupKind.coverageGap => 'From your material: $conceptName',
      };
}

class OutOfScope {
  const OutOfScope({this.alreadyTheoremOnly = false});
  final bool alreadyTheoremOnly; // the theorem-pool fallback found nothing either
  String get message => alreadyTheoremOnly
      ? 'No theorem-pool shorts match this either.'
      : "Not in your material. Search is limited to what you're studying.";
}

class SearchResponse {
  SearchResponse({
    required this.understanding,
    this.groups = const [],
    this.outOfScope,
    this.materialInactive = false,
    this.theoremOnly = false,
    this.fromCache = false,
  });

  final QueryUnderstanding understanding;
  final List<SearchGroup> groups;
  final OutOfScope? outOfScope;

  /// No active material: only theorem-pool results, with a notice (§1).
  final bool materialInactive;
  final bool theoremOnly;
  final bool fromCache;

  bool get isEmpty => groups.isEmpty && outOfScope == null;
}

class _Cand {
  _Cand(this.row);
  final Map<String, Object?> row;
  String get id => row['id']! as String;
  bool get isShort => row['is_short'] == 1;
  bool get inPool => row['in_theorem_pool'] == 1;
  double hybrid = 0;
  double score = 0;
}

final _formulaRe = RegExp(r'[∫∑∏√≤≥≠∂∇πθ∞]|\\[a-zA-Z]+|\^|_|=');

/// LaTeX and Unicode math to one comparable form.
String normalizeFormula(String s) {
  const cmds = {
    r'\int': '∫', r'\oint': '∮', r'\sum': '∑', r'\prod': '∏', r'\pi': 'π', r'\theta': 'θ', r'\infty': '∞',
    r'\sqrt': '√', r'\partial': '∂', r'\nabla': '∇', r'\cdot': '·', r'\times': '×', r'\le': '≤', r'\ge': '≥',
    r'\neq': '≠', r'\mid': '|', r'\to': '→', r'\alpha': 'α', r'\beta': 'β', r'\lambda': 'λ', r'\sigma': 'σ',
    r'\mu': 'μ', r'\varphi': 'φ', r'\phi': 'φ', r'\omega': 'ω',
  };
  var t = s;
  for (final e in (cmds.entries.toList()..sort((a, b) => b.key.length.compareTo(a.key.length)))) {
    t = t.replaceAll(e.key, e.value);
  }
  t = t
      .replaceAll(RegExp(r'\\(left|right|mathbf|mathrm|text|operatorname|displaystyle|,|;|!|quad)'), '')
      .replaceAll(RegExp(r'\\frac\{([^{}]*)\}\{([^{}]*)\}'), r'$1/$2')
      .replaceAll(RegExp(r'[{}\s]'), '')
      .replaceAll('−', '-')
      .toLowerCase();
  return t;
}

class SearchService {
  SearchService(this._db) : _matcher = ConceptMatcher(_db, threshold: 85);

  final AppDatabase _db;
  final ConceptMatcher _matcher;
  static const cacheTtl = Duration(hours: 1);

  // --- Stage 1: query understanding -------------------------------------------

  QueryUnderstanding understand(String query) {
    final q = query.trim();
    if (q.isEmpty) return QueryUnderstanding(QueryIntent.empty, q);

    if (_formulaRe.hasMatch(q)) {
      final hit = _matchFormula(q);
      if (hit != null) {
        return _conceptIntent(q, hit.$1, hit.$2)..viaFormula = true;
      }
      return QueryUnderstanding(QueryIntent.formula, q);
    }

    if (q.split(RegExp(r'\s+')).length <= 6) {
      final c = _matcher.match(q);
      if (c != null) return _conceptIntent(q, c.id, c.name);
    }
    return QueryUnderstanding(QueryIntent.natural, q);
  }

  QueryUnderstanding _conceptIntent(String q, String id, String name) {
    final aliases = parseJsonList(_db.select('SELECT aliases FROM concepts WHERE id = ?', [id]).first['aliases'] as String?);
    return QueryUnderstanding(QueryIntent.concept, q, conceptId: id, conceptName: name, expandedTerms: [name, ...aliases]);
  }

  /// Formula intent → nearest concept by its LaTeX (graph or material) or description.
  (String, String)? _matchFormula(String q) {
    final nq = normalizeFormula(q);
    if (nq.length < 3) return null;
    (String, String, double)? best;
    for (final r in _db.select('''
      SELECT c.id, c.canonical_name, c.latex, c.description,
             (SELECT group_concat(mc.latex, ' ') FROM material_concepts mc WHERE mc.concept_id = c.id) AS mlatex
      FROM concepts c''')) {
      for (final f in [r['latex'], r['mlatex'], r['description']].whereType<String>()) {
        final score = partialRatio(nq, normalizeFormula(f));
        if (score >= 80 && (best == null || score > best.$3)) {
          best = (r['id'] as String, r['canonical_name'] as String, score);
        }
      }
    }
    return best == null ? null : (best.$1, best.$2);
  }

  // --- Stage 2: scope ---------------------------------------------------------

  bool get hasActiveMaterial => _db.select('SELECT 1 FROM user_active_concepts LIMIT 1').isNotEmpty;

  bool _isActive(String conceptId) =>
      _db.select('SELECT 1 FROM user_active_concepts WHERE concept_id = ?', [conceptId]).isNotEmpty;

  bool _isPoolTheorem(String conceptId) => _db.select(
      "SELECT 1 FROM concepts WHERE id = ? AND in_theorem_pool = 1 AND subject = 'math'", [conceptId]).isNotEmpty;

  /// The candidate pool (same universe as the feeds). [theoremOnly] → pool shorts only.
  String _poolSql({required bool theoremOnly}) {
    final pool = "(v.is_short = 1 AND v.in_theorem_pool = 1 AND v.subject = 'math')";
    if (theoremOnly) return "v.status = 'active' AND $pool";
    return '''v.status = 'active' AND ($pool OR EXISTS (
      SELECT 1 FROM video_concepts vc JOIN user_active_concepts u ON u.concept_id = vc.concept_id
      WHERE vc.video_id = v.id AND vc.is_primary = 1))''';
  }

  // --- the pipeline -------------------------------------------------------------

  SearchResponse search(String query, {bool theoremOnly = false, int maxGroups = 8, int perGroup = 5}) {
    final u = understand(query);
    final materialInactive = !hasActiveMaterial;
    final restrict = theoremOnly || materialInactive;
    if (u.intent == QueryIntent.empty) {
      return SearchResponse(understanding: u, materialInactive: materialInactive, theoremOnly: restrict);
    }

    final cached = _cacheGet(query, restrict);
    if (cached != null) return cached;

    // Concept intent on a concept outside the universe (e.g. "series" → Infinite Series,
    // which you aren't studying): search your universe as free text instead, so
    // in-scope matches (Taylor, Fourier, geometric series) still come back grouped.
    // Nothing found → the out-of-scope card below.
    var effective = u;
    if (u.intent == QueryIntent.concept) {
      final id = u.conceptId!;
      final inScope = (!restrict && _isActive(id)) || _isPoolTheorem(id);
      if (!inScope) effective = QueryUnderstanding(QueryIntent.natural, u.raw);
    }

    final cands = _retrieve(effective, restrict);
    _rerank(effective, cands);
    final groups = _group(effective, cands, restrict: restrict, maxGroups: maxGroups, perGroup: perGroup);

    final response = groups.isEmpty
        ? SearchResponse(understanding: u, outOfScope: OutOfScope(alreadyTheoremOnly: theoremOnly),
            materialInactive: materialInactive, theoremOnly: restrict)
        : SearchResponse(understanding: u, groups: groups, materialInactive: materialInactive, theoremOnly: restrict);
    return _cachePut(query, restrict, response);
  }

  // --- Stage 3: hybrid retrieval ----------------------------------------------

  static const _videoCols = 'v.id, v.title, v.thumbnail_url, v.duration_sec, v.is_short, v.in_theorem_pool, v.subject';

  List<_Cand> _retrieve(QueryUnderstanding u, bool restrict) {
    final pool = _poolSql(theoremOnly: restrict);
    final byId = <String, _Cand>{};

    // Direct lookup for concept intent: every in-scope video tagged with the concept.
    if (u.intent == QueryIntent.concept) {
      for (final r in _db.select('''
        SELECT $_videoCols FROM videos v JOIN video_concepts vc ON vc.video_id = v.id
        WHERE vc.concept_id = ? AND $pool''', [u.conceptId])) {
        byId.putIfAbsent(r['id']! as String, () => _Cand(r));
      }
    }

    // BM25 over title, description and transcript, inside the pool.
    final terms = u.intent == QueryIntent.concept ? u.expandedTerms : [u.raw];
    final words = <String>{};
    for (final t in terms) {
      for (final w in normalizeText(t).split(' ')) {
        if (w.length >= 3 && !_searchStopwords.contains(w)) words.add(w);
      }
    }
    final phrases = [
      for (final t in u.intent == QueryIntent.concept ? u.expandedTerms : const <String>[])
        if (normalizeText(t).contains(' ')) '"${normalizeText(t)}"',
    ];
    final match = [...phrases, ...words.map((w) => '"$w"')].join(' OR ');
    if (match.isNotEmpty) {
      final rows = _db.select('''
        SELECT $_videoCols, bm25(videos_fts, 5.0, 2.0, 1.0) AS s
        FROM videos_fts JOIN videos v ON v.rowid = videos_fts.rowid
        WHERE videos_fts MATCH ? AND $pool ORDER BY s LIMIT 50''', [match]);
      if (rows.isNotEmpty) {
        final best = -(rows.first['s'] as num).toDouble();
        for (final r in rows) {
          final c = byId.putIfAbsent(r['id']! as String, () => _Cand(r));
          c.hybrid = best <= 0 ? 0 : (-(r['s'] as num).toDouble() / best).clamp(0, 1).toDouble();
        }
      }
    }
    return byId.values.toList();
  }

  // --- Stage 4: re-rank -------------------------------------------------------

  void _rerank(QueryUnderstanding u, List<_Cand> cands) {
    for (final c in cands) {
      final tags = _db.select('SELECT concept_id, is_primary FROM video_concepts WHERE video_id = ?', [c.id]);
      var s = 0.0;
      if (u.intent == QueryIntent.concept) {
        final tag = tags.where((t) => t['concept_id'] == u.conceptId).firstOrNull;
        if (tag != null) s += tag['is_primary'] == 1 ? 1.0 : 0.5;
      }
      final title = normalizeText(c.row['title']! as String);
      for (final term in u.expandedTerms) {
        final nt = normalizeText(term);
        if (nt.length >= 3 && title.contains(nt)) s += 0.3;
      }
      s += 0.3 * c.hybrid;
      if (c.inPool && !c.isShort) s -= 0.2;
      s -= 0.1 * _alreadyWatched(c.id);
      c.score = s;
    }
    cands.sort((a, b) => b.score.compareTo(a.score));
  }

  int _alreadyWatched(String videoId) =>
      _db.select('SELECT count(*) AS n FROM watch_history WHERE video_id = ? AND completed = 1', [videoId]).first['n']
          as int;

  // --- Stage 5: group + coverage gaps ----------------------------------------------

  List<SearchGroup> _group(QueryUnderstanding u, List<_Cand> cands,
      {required bool restrict, required int maxGroups, required int perGroup}) {
    final groups = <String, List<_Cand>>{};
    final kinds = <String, GroupKind>{};

    for (final c in cands) {
      // Which in-scope concept does this video belong to? Prefer the query's concept.
      final primaries = [
        for (final r in _db.select(
            'SELECT concept_id FROM video_concepts WHERE video_id = ? AND is_primary = 1 ORDER BY confidence DESC', [c.id]))
          r['concept_id'] as String,
      ];
      String? owner;
      GroupKind? kind;
      if (u.conceptId != null && primaries.contains(u.conceptId)) {
        owner = u.conceptId;
      } else {
        owner = primaries.where((p) => !restrict && _isActive(p)).firstOrNull ?? primaries.firstOrNull;
      }
      if (owner == null) continue;
      if (!restrict && _isActive(owner)) {
        kind = GroupKind.material;
      } else if (c.isShort && c.inPool) {
        kind = GroupKind.theorem;
      } else {
        continue; // out of scope for this concept
      }
      // Judged clearly off-topic for this concept → not shown (same as the feed).
      final offTopic = _db.select(
          'SELECT 1 FROM relevance_scores WHERE video_id = ? AND concept_id = ? AND topic_fit <= ?',
          [c.id, owner, offTopicFit]).isNotEmpty;
      if (offTopic) continue;
      (groups[owner] ??= []).add(c);
      kinds[owner] = kind;
    }

    final names = <String, String>{};
    String nameOf(String id) => names[id] ??=
        _db.select('SELECT canonical_name FROM concepts WHERE id = ?', [id]).first['canonical_name'] as String;

    final ordered = groups.keys.toList()
      ..sort((a, b) {
        if (a == u.conceptId) return -1;
        if (b == u.conceptId) return 1;
        // Theorem-pool query: pool shorts first, then material long-form (§11.6).
        return groups[b]!.first.score.compareTo(groups[a]!.first.score);
      });

    final out = <SearchGroup>[
      for (final id in ordered.take(maxGroups))
        SearchGroup(
          conceptId: id,
          conceptName: nameOf(id),
          kind: kinds[id]!,
          chapter: kinds[id] == GroupKind.material ? _chapterOf(id) : null,
          videos: [
            for (final c in groups[id]!.take(perGroup))
              FeedCard(
                videoId: c.id,
                title: c.row['title']! as String,
                thumbnailUrl: c.row['thumbnail_url'] as String?,
                durationSec: c.row['duration_sec'] as int?,
                isShort: c.isShort,
                conceptId: id,
                conceptName: nameOf(id),
                fromMaterial: kinds[id] == GroupKind.material,
                score: c.score,
              ),
          ],
        ),
    ];

    // Concept intent on an in-scope concept with no videos → coverage-gap card first.
    if (u.intent == QueryIntent.concept && !groups.containsKey(u.conceptId)) {
      if (!restrict && _isActive(u.conceptId!)) {
        out.insert(0, SearchGroup(conceptId: u.conceptId!, conceptName: u.conceptName!, kind: GroupKind.coverageGap,
            chapter: _chapterOf(u.conceptId!)));
      }
    }
    // …and its in-material prerequisites that have no videos (§11.5).
    if (u.intent == QueryIntent.concept && !restrict && _isActive(u.conceptId!)) {
      for (final r in _db.select('''
        SELECT p.id, p.canonical_name FROM concept_edges e JOIN concepts p ON p.id = e.to_concept
        JOIN user_active_concepts ua ON ua.concept_id = p.id
        WHERE e.from_concept = ? AND e.relation = 'requires' AND NOT EXISTS (
          SELECT 1 FROM video_concepts vc JOIN videos v ON v.id = vc.video_id
          WHERE vc.concept_id = p.id AND vc.is_primary = 1 AND v.status = 'active')
        ORDER BY p.canonical_name''', [u.conceptId])) {
        out.add(SearchGroup(
            conceptId: r['id'] as String, conceptName: r['canonical_name'] as String, kind: GroupKind.prerequisiteGap));
      }
    }

    // Natural-language queries: cap the total at 10 videos (§11.6).
    if (u.intent == QueryIntent.natural) {
      var left = 10;
      return [
        for (final g in out)
          if (left > 0)
            () {
              final take = g.videos.take(left).toList();
              left -= take.length;
              return SearchGroup(conceptId: g.conceptId, conceptName: g.conceptName, kind: g.kind, chapter: g.chapter, videos: take);
            }(),
      ];
    }
    return out;
  }

  String? _chapterOf(String conceptId) {
    final r = _db.select('''
      SELECT mc.section, mc.chapter FROM material_concepts mc JOIN materials m ON m.id = mc.material_id
      WHERE mc.concept_id = ? AND m.status = 'active' ORDER BY mc.importance DESC LIMIT 1''', [conceptId]).firstOrNull;
    if (r == null) return null;
    final s = (r['section'] ?? r['chapter']) as String?;
    return s == null ? null : RegExp(r'^\d+(\.\d+)*').firstMatch(s)?.group(0) ?? s;
  }

  // --- cache (§11.7) ------------------------------------------------------------

  /// Changes whenever anything search depends on changes (material, videos,
  /// tags, judgements), so cached results are never stale.
  String _librarySignature() {
    final r = _db.select('''
      SELECT (SELECT count(*) || ':' || coalesce(max(updated_at), 0) FROM user_active_concepts) AS a,
             (SELECT count(*) || ':' || coalesce(max(created_at), 0) FROM videos WHERE status = 'active') AS b,
             (SELECT count(*) FROM video_concepts) AS c,
             (SELECT count(*) || ':' || coalesce(max(judged_at), 0) FROM relevance_scores) AS d,
             (SELECT count(*) FROM watch_history WHERE completed = 1) AS e''').first;
    return '${r['a']}|${r['b']}|${r['c']}|${r['d']}|${r['e']}';
  }

  String _key(String query, bool restrict) =>
      sha256.convert(utf8.encode('${query.trim().toLowerCase()}|$restrict|${_librarySignature()}')).toString();

  final Map<String, SearchResponse> _memo = {};

  SearchResponse? _cacheGet(String query, bool restrict) {
    final key = _key(query, restrict);
    final hit = _memo[key];
    if (hit == null) return null;
    final row = _db.select('SELECT expires_at FROM search_cache WHERE query_hash = ?', [key]).firstOrNull;
    if (row == null || (row['expires_at'] as int) < nowMs()) {
      _memo.remove(key);
      return null;
    }
    return SearchResponse(
      understanding: hit.understanding,
      groups: hit.groups,
      outOfScope: hit.outOfScope,
      materialInactive: hit.materialInactive,
      theoremOnly: hit.theoremOnly,
      fromCache: true,
    );
  }

  SearchResponse _cachePut(String query, bool restrict, SearchResponse r) {
    final key = _key(query, restrict);
    _memo[key] = r;
    final now = nowMs();
    _db.execute(
      'INSERT OR REPLACE INTO search_cache (query_hash, query_text, results, created_at, expires_at) VALUES (?, ?, ?, ?, ?)',
      [key, query, jsonEncode({'groups': [for (final g in r.groups) g.conceptId], 'out_of_scope': r.outOfScope != null}),
       now, now + cacheTtl.inMilliseconds],
    );
    return r;
  }
}

const _searchStopwords = {
  'the', 'and', 'for', 'with', 'that', 'this', 'what', 'how', 'why', 'does', 'can', 'are', 'from', 'into',
  'about', 'explain', 'explained', 'video', 'videos', 'lesson', 'tutorial', 'intro', 'introduction',
  'two', 'one', 'use', 'using', 'when', 'which', 'you', 'your', 'get', 'find',
};
