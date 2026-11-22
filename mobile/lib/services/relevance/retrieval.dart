/// Layer A: multi-signal retrieval per concept (§9.1), on the device.
///
///   Signal 1  explicit concept tag (highest precision)
///   Signal 2  the material's *statement* matched against video text
///             (BM25 over title + description + transcript; the on-device
///             stand-in for statement embeddings — no second model to download)
///   Signal 3  graph neighbourhood: videos for the concept's prerequisites
///
/// Statement, not name: "Integration by Parts" alone matches too broadly; the
/// statement's words disambiguate.
library;

import '../../data/app_database.dart';
import '../text_match.dart';

enum Signal { tag, statement, prerequisite }

class ConceptContext {
  ConceptContext({
    required this.id,
    required this.name,
    required this.statement,
    required this.difficulty,
    this.chapter,
    this.section,
    this.prerequisiteIds = const [],
    this.prerequisiteNames = const [],
  });

  final String id;
  final String name;
  final String statement; // best_statement for active concepts, else the graph description
  final String difficulty;
  final String? chapter;
  final String? section;
  final List<String> prerequisiteIds;
  final List<String> prerequisiteNames;
}

class Candidate {
  Candidate({
    required this.videoId,
    required this.title,
    required this.description,
    required this.transcript,
    required this.durationSec,
    required this.isShort,
  });

  final String videoId;
  final String title;
  final String description;
  final String transcript;
  final int? durationSec;
  final bool isShort;
  final Set<Signal> signals = {};
  double bm25 = 0; // higher = better (negated SQLite bm25)
}

ConceptContext? conceptContext(AppDatabase db, String conceptId) {
  final c = db.select('SELECT canonical_name, description FROM concepts WHERE id = ?', [conceptId]).firstOrNull;
  if (c == null) return null;
  final uac = db.select('SELECT best_statement, best_difficulty FROM user_active_concepts WHERE concept_id = ?',
      [conceptId]).firstOrNull;
  final mc = db.select('''
    SELECT mc.chapter, mc.section FROM material_concepts mc JOIN materials m ON m.id = mc.material_id
    WHERE mc.concept_id = ? AND m.status = 'active' ORDER BY mc.importance DESC LIMIT 1''', [conceptId]).firstOrNull;
  final prereqs = db.select('''
    SELECT p.id, p.canonical_name FROM concept_edges e JOIN concepts p ON p.id = e.to_concept
    WHERE e.from_concept = ? AND e.relation = 'requires' ORDER BY p.canonical_name''', [conceptId]);
  return ConceptContext(
    id: conceptId,
    name: c['canonical_name'] as String,
    statement: (uac?['best_statement'] as String?) ?? (c['description'] as String),
    difficulty: (uac?['best_difficulty'] as String?) ?? 'undergrad',
    chapter: mc?['chapter'] as String?,
    section: mc?['section'] as String?,
    prerequisiteIds: [for (final r in prereqs) r['id'] as String],
    prerequisiteNames: [for (final r in prereqs) r['canonical_name'] as String],
  );
}

const _stopwords = {
  'the', 'and', 'for', 'with', 'that', 'this', 'from', 'are', 'its', 'into', 'then', 'than', 'their', 'there',
  'which', 'when', 'where', 'what', 'each', 'every', 'any', 'all', 'can', 'may', 'has', 'have', 'been', 'being',
  'was', 'were', 'will', 'would', 'such', 'some', 'one', 'two', 'way', 'used', 'using', 'use', 'also', 'not',
  'but', 'our', 'you', 'your', 'given', 'gives', 'give', 'let', 'say', 'said', 'same', 'other', 'more', 'most',
  'only', 'over', 'under', 'between', 'about', 'how', 'why', 'who', 'is', 'of', 'in', 'on', 'to', 'by', 'an',
  'it', 'as', 'at', 'be', 'or', 'if', 'so', 'we', 'a',
  // Too generic in math/science text to discriminate between concepts.
  'function', 'functions', 'number', 'numbers', 'value', 'values', 'equation', 'equations', 'set', 'sets',
  'real', 'point', 'points', 'line', 'lines', 'form', 'case', 'cases', 'result', 'results', 'method',
  'example', 'examples', 'problem', 'problems', 'variable', 'variables', 'constant', 'term', 'terms',
};

/// Distinctive words of the statement and name, for the BM25 query.
List<String> statementKeywords(ConceptContext c, {int max = 14}) {
  final words = <String>[];
  for (final w in normalizeText('${c.name} ${c.statement}').split(' ')) {
    if (w.length < 3 || _stopwords.contains(w) || RegExp(r'^\d+$').hasMatch(w) || words.contains(w)) continue;
    words.add(w);
    if (words.length >= max) break;
  }
  return words;
}

String _ftsQuery(ConceptContext c) {
  final name = normalizeText(c.name);
  final terms = statementKeywords(c).map((w) => '"$w"');
  return [if (name.contains(' ')) '"$name"', ...terms].join(' OR ');
}

const _videoCols = 'v.id, v.title, v.description, v.transcript, v.duration_sec, v.is_short';

Candidate _row(Map<String, Object?> r) => Candidate(
      videoId: r['id']! as String,
      title: r['title']! as String,
      description: r['description']! as String,
      transcript: r['transcript']! as String,
      durationSec: r['duration_sec'] as int?,
      isShort: r['is_short'] == 1,
    );

/// Candidates for [c], deduplicated by video; tag hits first, then by BM25.
List<Candidate> retrieveCandidates(AppDatabase db, ConceptContext c, {int topK = 50}) {
  final byId = <String, Candidate>{};
  Candidate add(Map<String, Object?> r, Signal s) => (byId[r['id']! as String] ??= _row(r))..signals.add(s);

  // Signal 1: explicit concept tag.
  for (final r in db.select('''
    SELECT $_videoCols FROM videos v JOIN video_concepts vc ON vc.video_id = v.id
    WHERE vc.concept_id = ? AND v.status = 'active' ORDER BY vc.is_primary DESC, vc.confidence DESC LIMIT ?''',
      [c.id, topK])) {
    add(r, Signal.tag);
  }

  // Signal 2: statement keywords against video text (BM25). A single shared
  // word is too weak: keep a hit only if it has the concept's name or at
  // least two distinct statement keywords.
  final q = _ftsQuery(c);
  final keywords = statementKeywords(c);
  final name = normalizeText(c.name);
  bool strongEnough(Map<String, Object?> r) {
    final text = normalizeText('${r['title']} ${r['description']} ${r['transcript']}');
    if (text.contains(name)) return true;
    final words = {for (final w in text.split(' ')) _stem(w)};
    return keywords.where((k) => words.contains(_stem(k))).length >= 2;
  }

  if (q.isNotEmpty) {
    for (final r in db.select('''
      SELECT $_videoCols, bm25(videos_fts, 5.0, 2.0, 1.0) AS score
      FROM videos_fts JOIN videos v ON v.rowid = videos_fts.rowid
      WHERE videos_fts MATCH ? AND v.status = 'active'
      ORDER BY score LIMIT ?''', [q, topK])) {
      if (!strongEnough(r)) continue;
      add(r, Signal.statement).bm25 = -(r['score'] as num).toDouble();
    }
  }

  // Signal 3: prerequisite neighbourhood.
  if (c.prerequisiteIds.isNotEmpty) {
    final marks = List.filled(c.prerequisiteIds.length, '?').join(',');
    for (final r in db.select('''
      SELECT DISTINCT $_videoCols FROM videos v JOIN video_concepts vc ON vc.video_id = v.id
      WHERE vc.concept_id IN ($marks) AND vc.is_primary = 1 AND v.status = 'active' LIMIT ?''',
        [...c.prerequisiteIds, topK ~/ 2])) {
      add(r, Signal.prerequisite);
    }
  }

  return byId.values.toList()
    ..sort((a, b) {
      final t = (b.signals.contains(Signal.tag) ? 1 : 0).compareTo(a.signals.contains(Signal.tag) ? 1 : 0);
      return t != 0 ? t : b.bm25.compareTo(a.bm25);
    });
}

/// Crude stem for keyword overlap: the first six letters ("integration",
/// "integrate", "integrating" → "integr"). The FTS index itself uses Porter.
String _stem(String w) => w.length <= 6 ? w : w.substring(0, 6);
