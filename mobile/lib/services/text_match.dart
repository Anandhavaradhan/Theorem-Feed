/// Fuzzy string matching (a Dart port of rapidfuzz's `ratio` / `token_set_ratio`).
library;

import 'dart:math' as math;

/// Lowercase, strip accents/punctuation (keeps letters, digits, spaces), collapse spaces.
String normalizeText(String s) {
  const accents = {'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e', 'í': 'i',
    'ï': 'i', 'ó': 'o', 'ö': 'o', 'ô': 'o', 'ú': 'u', 'ü': 'u', 'ç': 'c', 'ñ': 'n', 'š': 's', 'ő': 'o', 'ű': 'u'};
  final lower = s.toLowerCase().split('').map((c) => accents[c] ?? c).join();
  return lower
      .replaceAll(RegExp(r"['’]s\b"), '') // Bayes's → bayes
      .replaceAll(RegExp(r"['’]"), '') // Bayes' → bayes
      .replaceAll(RegExp(r"[^a-z0-9 ]+"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}

/// Indel-style similarity in 0..100 (like rapidfuzz `ratio`, using Levenshtein).
double ratio(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 100;
  final total = a.length + b.length;
  return 100 * (total - _indel(a, b)) / total;
}

int _indel(String a, String b) {
  // Indel distance = len(a) + len(b) - 2 * LCS(a, b).
  if (a.isEmpty || b.isEmpty) return a.length + b.length;
  final prev = List<int>.filled(b.length + 1, 0);
  final cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      cur[j] = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? prev[j - 1] + 1 : math.max(prev[j], cur[j - 1]);
    }
    prev.setAll(0, cur);
  }
  return a.length + b.length - 2 * prev[b.length];
}

/// rapidfuzz `token_set_ratio`: compares the shared token set against each side's remainder.
double tokenSetRatio(String a, String b) {
  final ta = normalizeText(a).split(' ').where((t) => t.isNotEmpty).toSet();
  final tb = normalizeText(b).split(' ').where((t) => t.isNotEmpty).toSet();
  if (ta.isEmpty || tb.isEmpty) return 0;
  final inter = (ta.intersection(tb).toList()..sort()).join(' ');
  final diffA = (ta.difference(tb).toList()..sort()).join(' ');
  final diffB = (tb.difference(ta).toList()..sort()).join(' ');
  // One side's tokens are a subset of the other's → perfect match (as in rapidfuzz).
  if (inter.isNotEmpty && (diffA.isEmpty || diffB.isEmpty)) return 100;
  final combA = [inter, diffA].where((s) => s.isNotEmpty).join(' ');
  final combB = [inter, diffB].where((s) => s.isNotEmpty).join(' ');
  return [
    if (inter.isNotEmpty) ratio(inter, combA),
    if (inter.isNotEmpty) ratio(inter, combB),
    ratio(combA, combB),
  ].reduce(math.max);
}

/// Levenshtein-based similarity in 0..100 (typo tolerance for single words).
double editRatio(String a, String b) {
  final n = math.max(a.length, b.length);
  return n == 0 ? 100 : 100 * (n - _levenshtein(a, b)) / n;
}

/// rapidfuzz-style `partial_ratio`: the best [ratio] of the shorter string
/// against every same-length window of the longer one.
double partialRatio(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final (short, long) = a.length <= b.length ? (a, b) : (b, a);
  if (long.contains(short)) return 100;
  var best = 0.0;
  for (var i = 0; i + short.length <= long.length; i++) {
    final r = ratio(short, long.substring(i, i + short.length));
    if (r > best) best = r;
    if (best == 100) break;
  }
  return best;
}
