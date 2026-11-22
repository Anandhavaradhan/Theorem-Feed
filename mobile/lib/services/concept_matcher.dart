/// Maps free-text concept names (from the LLM, or a search query) onto
/// concepts in the on-device knowledge graph.
///
///   1. exact match on canonical name or any alias (normalized)
///   2. trigram-index candidates scored with token_set_ratio ≥ [threshold]
library;

import '../data/app_database.dart';
import 'text_match.dart';

class ConceptRef {
  ConceptRef(this.id, this.name, this.score);
  final String id;
  final String name;
  final double score;
  @override
  String toString() => 'ConceptRef($name, $score)';
}

class ConceptMatcher {
  ConceptMatcher(this._db, {this.threshold = 85});
  final AppDatabase _db;
  final double threshold;

  ConceptRef? match(String name) {
    final norm = normalizeText(name);
    if (norm.isEmpty) return null;

    final candidates = <String, (String, List<String>)>{};
    void addRows(Iterable<Map<String, Object?>> rows) {
      for (final r in rows) {
        candidates[r['id']! as String] = (r['canonical_name']! as String, parseJsonList(r['aliases'] as String?));
      }
    }

    // Trigram index needs ≥3 chars per term; quote each word as a phrase.
    final terms = norm.split(' ').where((t) => t.length >= 3).map((t) => '"$t"').toList();
    if (terms.isNotEmpty) {
      addRows(_db.select('''
        SELECT c.id, c.canonical_name, c.aliases FROM concepts_trgm t
        JOIN concepts c ON c.rowid = t.rowid
        WHERE concepts_trgm MATCH ? LIMIT 50
      ''', [terms.join(' OR ')]));
    }
    // Typo tolerance: trigram terms may all miss on a misspelling; fall back to a full scan
    // (the graph is a few hundred rows).
    if (candidates.isEmpty) {
      addRows(_db.select('SELECT id, canonical_name, aliases FROM concepts'));
    }

    ConceptRef? best;
    for (final e in candidates.entries) {
      final (canonical, aliases) = e.value;
      for (final n in [canonical, ...aliases]) {
        final nn = normalizeText(n);
        final score = nn == norm ? 101.0 : _score(norm, nn);
        if (score >= threshold && (best == null || score > best.score)) {
          best = ConceptRef(e.key, canonical, score);
        }
      }
    }
    return best;
  }

  /// token_set_ratio, but guard against a short name matching as a subset of a
  /// longer, different concept ("Series" ⊂ "Taylor Series").
  double _score(String a, String b) {
    final ta = a.split(' ').toSet(), tb = b.split(' ').toSet();
    final subset = ta.length != tb.length && (ta.containsAll(tb) || tb.containsAll(ta));
    if (subset) return ratio(a, b);
    final set = tokenSetRatio(a, b);
    return set >= threshold ? set : editRatio(a, b);
  }

  /// Unique matched concepts for a list of names, in order.
  List<ConceptRef> matchAll(Iterable<String> names) {
    final seen = <String>{};
    return [
      for (final n in names)
        if (match(n) case final ConceptRef r when seen.add(r.id)) r,
    ];
  }
}
