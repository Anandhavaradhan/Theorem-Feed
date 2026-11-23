/// Fast, rules-first concept extraction for clear, text-based PDFs. No AI
/// needed; runs in milliseconds.
///
/// What well-made notes tell us, strongest signal first:
///   1. Headings          "7.1 Integration by Parts", "4 Refraction of light"
///                        (sentence-like ones such as "It bends towards the normal" are not names)
///   2. Labelled blocks   "Theorem 7.1 (Mean Value Theorem). …" / "Definition 7.4. …"
///   3. Box titles        "Plane mirror" on its own line, followed by its explanation
///   4. Lead-in terms     "Brightness — depends on …", "• Colour is …"
///   5. Defining phrases  "… is called integration by parts.", "A lens is a …",
///                        "… is the critical angle."
///   6. Vocabulary lists  "Focal length f / Power P"
///   7. Known concept names, counted across the document
///
/// Confident finds are concepts straight away. Weak ones (a lone word, a passing
/// mention, a phrase in brackets) are marked needsCheck for the on-device AI.
/// Concepts only mentioned in passing become prerequisites of the section's concept.
/// Sections that only practise (question banks, formula sheets, exam drills)
/// are not mined.
library;

import '../text_match.dart';
import 'concept_extractor.dart';
import 'text_pipeline.dart';

/// Names and aliases of known concepts (the graph plus anything created before).
class ConceptDictionary {
  ConceptDictionary(Iterable<(String name, List<String> aliases, String type, String subject)> concepts) {
    for (final (name, aliases, type, subject) in concepts) {
      _types[name] = type;
      _subjects[name] = subject;
      for (final phrase in {name, ...aliases}) {
        final n = normalizeText(phrase);
        // Very short or single generic words ("set", "group", "limit") match far too
        // much ordinary text; they still count when a heading/label/definition names them.
        if (n.length < 4) continue;
        _phrases.add((n, name, RegExp('\\b${RegExp.escape(n)}\\b')));
      }
    }
    _phrases.sort((a, b) => b.$1.length.compareTo(a.$1.length)); // longest first
  }

  final _phrases = <(String phrase, String name, RegExp re)>[];
  final _types = <String, String>{};
  final _subjects = <String, String>{};

  String? typeOf(String name) => _types[name];
  bool knows(String name) => _types.containsKey(name) || mostSpecific(name) != null || _exact(name) != null;

  String? _exact(String text) {
    final t = normalizeText(text);
    for (final (phrase, name, _) in _phrases) {
      if (phrase == t) return name;
    }
    return null;
  }

  /// The subject most of the known concepts in [text] belong to; null if fewer
  /// than 3 mentions.
  String? dominantSubject(String text) {
    final counts = <String, int>{};
    var total = 0;
    mentions(text).forEach((name, n) {
      final s = _subjects[name];
      if (s == null) return;
      counts[s] = (counts[s] ?? 0) + n;
      total += n;
    });
    if (total < 3) return null;
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  /// Concept name → number of mentions in [text] (overlaps resolved longest-first).
  Map<String, int> mentions(String text) {
    var t = normalizeText(text);
    final out = <String, int>{};
    for (final (phrase, name, re) in _phrases) {
      if (!t.contains(phrase)) continue;
      final n = re.allMatches(t).length;
      if (n == 0) continue;
      out[name] = (out[name] ?? 0) + n;
      t = t.replaceAll(re, ' '); // don't count "series" inside "taylor series" again
    }
    return out;
  }

  /// The most specific known concept mentioned in [text], if any.
  String? mostSpecific(String text) {
    final t = normalizeText(text);
    for (final (phrase, name, re) in _phrases) {
      if (t.contains(phrase) && re.hasMatch(t) && phrase.contains(' ')) return name;
    }
    return null;
  }
}

// --- what is (not) a concept name -------------------------------------------

/// Sections that only practise or summarise: not mined for concepts.
final _practiceSectionRe = RegExp(
  r'^(formula sheet|formulae|formulas|summary|exercises?|problems?( set)?|review( questions)?|chapter review|'
  r'practice( questions| problems)?|homework|answers?|solutions?|worked examples?|examples?|revision|recap|'
  r'contents|index|references|bibliography|appendix.*|further reading|(learning )?objectives|preface|key terms|'
  r'notes|questions|introduction|overview|conclusion|key points.*|points to remember|things to remember|'
  r'.*\bquestion bank\b.*|.*\bexam questions?\b.*|.*\bdrill\b.*|.*\bmcqs?\b.*|.*\bmultiple[- ]choice\b.*|'
  r'.*\bmock (test|exam)\b.*|.*\bprevious years?\b.*|.*\bpractice (test|paper)\b.*)$',
  caseSensitive: false,
);

/// Box titles that label a kind of box, not a concept.
const _boxLabels = [
  'definition', 'definitions', 'exam trap', 'exam tip', 'note', 'notes', 'remember', 'conclusion', 'example',
  'examples', 'worked example', 'summary', 'answer', 'answers', 'solution', 'solutions', 'key idea', 'key ideas',
  'key point', 'key points', 'tip', 'tips', 'warning', 'caution', 'important', 'activity', 'experiment',
  'observation', 'observations', 'factor by factor', 'figure', 'fig', 'table', 'how to', 'which', 'why', 'what',
  'so', 'hence', 'therefore', 'thus', 'also', 'check', 'result', 'results', 'method', 'procedure', 'aim', 'uses',
  'use', 'common mistake', 'common mistakes', 'did you know', 'try this', 'exercise', 'problem', 'question',
  'questions', 'hint', 'shortcut', 'trick', 'fact', 'facts', 'recap', 'review', 'vocabulary', 'glossary',
  'the wave vocabulary', 'in short', 'in brief', 'constants', 'common molar masses', 'key balanced equations',
  'key equations', 'key formulae', 'key formulas', 'formulae', 'formulas', 'shape', 'example', 'bp+lp', 'direction', 'proof', 'remark', 'given', 'find', 'solve', 'step',
  'case', 'derivation', 'illustration', 'applications', 'advantages', 'disadvantages', 'limitations', 'units',
];

bool _isBoxLabel(String title) {
  final t = title.toLowerCase().replaceAll(RegExp(r'[:.]+$'), '').trim();
  if (RegExp(r'\b(vocabulary|glossary|key terms|summary)\b').hasMatch(t)) return true;
  for (final l in _boxLabels) {
    if (t == l || t.startsWith('$l ') || t.startsWith('$l:')) return true;
  }
  return false;
}

const _sentenceVerbs = {
  'is', 'are', 'was', 'were', 'does', 'do', 'did', "doesn't", "isn't", "don't", 'must', 'can', 'cannot', "can't",
  'should', 'will', 'would', 'needs', 'depends', 'carries', 'looks', 'look', 'has', 'have', 'travels', 'makes',
  'gives', 'goes', 'becomes', 'means', 'tells', 'moves', 'happens', 'matters', 'comes', 'gets', 'behaves', 'stays',
  'that', 'which', 'why', 'how',
};
const _openers = {
  'what', 'why', 'how', 'when', 'where', 'which', 'who', 'it', 'this', 'that', 'these', 'those', 'there', 'we',
  'you', 'here', 'so', 'let', 'our', 'your', 'my', 'some', 'more', 'other', 'another', 'all', 'both', 'each',
};
const _articlesEtc = {'a', 'an', 'the', 'your', 'our', 'its', 'it', 'them', 'this', 'these', 'two', 'any'};

/// "It bends towards the normal", "Light needs no medium", "Describing a lens",
/// "Faster than light" — fine as headings, useless as concept names.
bool _sentenceLike(String s) {
  if (s.trim().endsWith('?')) return true;
  final words = s.toLowerCase().replaceAll(RegExp(r"[^a-z0-9'’ -]"), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return true;
  if (_openers.contains(words.first)) return true;
  if (words.length > 1 && words[1] == 'than') return true;
  if (words.first.endsWith('ing') && words.first.length > 5 && words.length > 1 && _articlesEtc.contains(words[1])) {
    return true;
  }
  return words.skip(1).any(_sentenceVerbs.contains);
}

final _leadStripRe = RegExp(
    r'^(?:(?:uses|applications|types|kinds|examples|introduction|basics|properties|more|a note|notes) (?:of|to|on) |'
    r'(?:two|three|four|five|several|different|the two|the three) (?:kinds|types|sorts|forms) of )',
    caseSensitive: false);
final _trailingSymbolRe = RegExp(r'\s+[A-Za-zα-ωΑ-Ωϕϑ](?:\s*\(or [^)]{1,10}\))?$');

String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// The concept a heading or box title names, or null if it names none.
///   "What is light?"                        → Light
///   "Reflection — mirrors and images"       → Reflection
///   "Faster than light: Cherenkov radiation" → Cherenkov radiation
///   "Pipe closed at one end (flute, …)"     → Pipe closed at one end
///   "Uses of total internal reflection"     → Total internal reflection
///   "The lens formula — the one to learn"   → Lens formula
///   "It bends towards the normal"           → null
String? conceptNameFromTitle(String raw) {
  var t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  // "What a converging (convex) lens does" → "Converging lens": a term the
  // author glossed in brackets is a concept even inside a sentence-like heading.
  final glossed = RegExp(r"\b([a-z][a-z\-]{3,}) \(([a-z][a-z\-]{3,})\) ([a-z][a-z\-]{2,})\b", caseSensitive: false).firstMatch(t);
  if (glossed != null && _sentenceLike(t.replaceAll(RegExp(r'\s*\([^)]*\)'), ''))) {
    return _cap('${glossed.group(1)!.toLowerCase()} ${glossed.group(3)!.toLowerCase()}');
  }
  final q = RegExp(r'^what (?:is|are) (?:an? |the )?(.+?)\s*\??$', caseSensitive: false).firstMatch(t);
  if (q != null) t = q.group(1)!;
  t = t.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
  final parts = t.split(RegExp(r'\s*(?::|—|\s[–-]\s)\s*'));
  for (var i = 0; i < parts.length && i < 2; i++) {
    var c = parts[i].trim().replaceAll(RegExp(r'[.?!:;,]+$'), '').trim();
    if (c.isEmpty) continue;
    if (i > 0 && RegExp(r'^(the|a|an|how|why|what|it)\b', caseSensitive: false).hasMatch(c)) continue;
    c = c.replaceFirst(_leadStripRe, '').replaceFirst(RegExp(r'^(the|a|an) ', caseSensitive: false), '');
    if (c.split(' ').length > 1) c = c.replaceFirst(_trailingSymbolRe, '');
    if (c.length < 3 || RegExp(r'\d').hasMatch(c) || _sentenceLike(c) || c.split(' ').length > 7) continue;
    if (c.contains(',') || !RegExp(r'[A-Za-z]{3}').hasMatch(c)) continue;
    return _cap(c);
  }
  return null;
}

// --- regexes ----------------------------------------------------------------

final _labelRe = RegExp(
  r'^(Theorem|Lemma|Proposition|Corollary|Definition|Formula|Law|Principle|Rule|Algorithm|Identity)'
  r'(?=\s*(?:\d|\(|[.:—–-]|$)|\s+[A-Z])\s*(\d+(?:\.\d+)*)?\s*(?:\(([^)]{3,80})\))?\s*[.:]?\s*(.*)$',
  caseSensitive: false,
  dotAll: true,
);

final _labelPrefixRe = RegExp(
    r'^(Definition|Theorem|Lemma|Law|Principle|Proposition|Corollary)\s*(\d+(\.\d+)*)?\s*[.:]?\s+(?=[A-Z])');

const _labelType = {
  'theorem': 'theorem', 'lemma': 'theorem', 'proposition': 'theorem', 'corollary': 'theorem',
  'law': 'theorem', 'principle': 'theorem', 'identity': 'formula', 'definition': 'definition',
  'formula': 'formula', 'rule': 'technique', 'algorithm': 'technique',
};

const _termEnd = r'(?=\s*[.,;:(—]| if\b| when\b| and\b| for\b| which\b| because\b| that\b| in\b| of\b|$)';

/// "… is called X", "… called a real image", "known as X", "we call it X" (sure),
/// "said to be X" (adjectives mostly: checked).
final _definingRes = <(RegExp, bool sure)>[
  (RegExp(r'\b(?:(?:is|are|was|were) )?called (?:an? |the )?([a-z][a-z\-’ ]{2,40}?)' + _termEnd), true),
  (RegExp(r'\b(?:is|are) known as (?:an? |the )?([a-z][a-z\-’ ]{2,40}?)' + _termEnd), true),
  (RegExp(r'\bwe call (?:this|it|such \w+|them) (?:an? |the )?([a-z][a-z\-’ ]{2,40}?)' + _termEnd), true),
  (RegExp(r'\b(?:is|are) said to be (?:an? )?([a-z][a-z\-’ ]{2,40}?)' + _termEnd), false),
];

/// "A lens is a piece of glass …", "Colour is how …", "Refraction means …".
final _subjectDefRe = RegExp(
  r"^(?:(?:An?|The)\s+)?([A-Za-z][A-Za-z'’\-]*(?:\s+[a-z][a-z'’\-]*){0,3})(?:\s*\([^)]{1,30}\))?\s+"
  r'(?:is|are|means|refers to)\s+(?:an?\b|the\b|how\b|when\b|defined\b|said\b|measured\b|a measure\b)',
);

/// "The angle … is the critical angle.", "This splitting … is dispersion.",
/// "A beam of a single colour is monochromatic light." — the name is at the end.
final _predicateDefRe = RegExp(
  r'^(?:This|These|That|Such|The (?:ratio|quantity|phenomenon|effect|process|property|number|time|distance)|'
  r'A (?:sound|mixture|combination|wave|motion|body|point|quantity))\b.*\b(?:is|are) (?:(?:the|an?) )?'
  r"([a-z][a-z\-’']*(?: [a-z][a-z\-’']*){0,2})\s*\.?$",
);

/// "(total internal reflection)." / ": diffuse reflection." at a sentence end.
final _bracketTermRe = RegExp(r'\(([a-z][a-z\- ]{4,40})\)\s*\.?$');
final _colonTermRe = RegExp(r':\s*([a-z][a-z\- ]{4,40})\.$');

/// "Brightness — depends on …", "1. Elasticity — when …", "Uses: …".
final _leadInRe = RegExp(
  r"^([A-Z][A-Za-z'’\- ]{2,40}?)(?:\s*\(([^)]{1,40})\))?\s*(?:\s—|—|\s–\s|:)\s*(.{6,})",
  dotAll: true,
);
final _bulletRe = RegExp(r'^(?:\d{1,3}[.)]|[•▪◦\-–*]|\([a-z0-9]\))\s*');

/// Vocabulary-list lines: "Focal length f", "Power P", "Frequency f (or ν)".
final _glossLineRe = RegExp(r"^([A-Z][a-z]+(?:\s[a-z]{2,}){0,2})(\s+[A-Za-zα-ωϕϑ](?:\s*\(or [^)]{1,12}\))?)?$");

/// Words that never open a concept name.
const _badOpeners = {
  'this', 'it', 'that', 'there', 'each', 'every', 'so', 'here', 'which', 'what', 'one', 'all', 'both', 'such', 'its',
  'his', 'her', 'their', 'our', 'your', 'we', 'you', 'they', 'he', 'she', 'when', 'if', 'then', 'at', 'on', 'in',
  'with', 'by', 'for', 'from', 'as', 'no', 'not', 'how', 'why', 'where', 'increases', 'decreases', 'recognising',
  'recognizing', 'using', 'finding', 'common', 'key', 'important', 'useful', 'some', 'few', 'more',
};

/// Generic words that are not concepts on their own.
const _notConcepts = {
  'series', 'constants', 'data', 'values', 'average', 'sum', 'total', 'shape', 'exceptions', 'trends', 'speed',
  'answer', 'result', 'reason', 'idea',
  'point', 'trick', 'rule of thumb', 'key', 'difference', 'same', 'first', 'second', 'last', 'other', 'next', 'thing',
  'way', 'best', 'only', 'aim', 'goal', 'question', 'problem', 'solution', 'example', 'figure', 'table', 'graph',
  'unit', 'value', 'number', 'formula', 'equation', 'method', 'note', 'case', 'step', 'part', 'end', 'start',
};

final _sentenceSplit = RegExp(r'(?<=[.!?])\s+(?=[A-Z0-9•(])');

List<String> _sentences(String text) => text.split(_sentenceSplit).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

String _clip(String s, [int n = 400]) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > n ? '${t.substring(0, n - 3)}...' : t;
}

String _titleCase(String s) => s
    .split(' ')
    .map((w) => w.isEmpty ? w : const {'of', 'by', 'and', 'the', 'in', 'for', 'to', 'a', 'an', 'on'}.contains(w)
        ? w
        : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

String _guessType(String name) {
  final n = name.toLowerCase();
  if (RegExp(r'\b(theorem|lemma|law|principle|inequality|identity|correction)\b').hasMatch(n)) return 'theorem';
  if (RegExp(r'\b(formula|equation)\b').hasMatch(n)) return 'formula';
  if (RegExp(r'\b(method|rule|test|substitution|algorithm|technique|integration by|decomposition)\b').hasMatch(n)) {
    return 'technique';
  }
  return 'concept';
}

final _notNameRe = RegExp(
    r'\b(problems?|questions?|examples?|exercises?|numericals?|tricks?|vocabulary|glossary|summary|revision|'
    r'drill|recap|vs|versus|rules for)\b');

/// A part or a position of something rather than a concept: "Closed end",
/// "Open end", "Lowest frequency", "First point".
const _partNouns = {'end', 'ends', 'side', 'sides', 'part', 'parts', 'point', 'points', 'edge', 'edges', 'half',
  'top', 'bottom', 'case', 'cases', 'way', 'ways', 'step', 'steps', 'type', 'types', 'kind', 'kinds'};
const _rankWords = {'lowest', 'highest', 'first', 'second', 'third', 'last', 'next', 'previous', 'least', 'most',
  'smallest', 'largest', 'biggest', 'maximum', 'minimum', 'same', 'other', 'whole', 'entire'};

bool _usableTerm(String term) {
  final t = term.trim().toLowerCase();
  if (t.length < 3 || _notConcepts.contains(t) || _badOpeners.contains(t.split(' ').first)) return false;
  final words = t.split(' ');
  // Not a name: ends in a small word ("Distance node to"), a lone participle
  // ("Unpaired", "Reflected"), or a phrase with a verb in it ("Sound coming up").
  if (const {'to', 'of', 'the', 'a', 'an', 'from', 'in', 'at', 'by', 'for', 'with', 'and', 'or', 'up', 'between', 'than',
        'into', 'per', 'over', 'under', 'about'}.contains(words.last) &&
      words.length > 1) {
    return false;
  }
  if (words.length == 1 && RegExp(r'^[a-z]{4,}ed$').hasMatch(t)) return false;
  if (words.skip(1).any((w) => w.length > 5 && w.endsWith('ing'))) return false;
  // Two words only: "Closed end", "Lowest frequency" — not "Integration by Parts".
  if (words.length == 2 && (_partNouns.contains(words.last) || _rankWords.contains(words.first))) return false;
  if (_notNameRe.hasMatch(t)) return false;
  return t.split(' ').length <= 7 && !RegExp(r'\d').hasMatch(t);
}

// --- formula sheets and summaries ----------------------------------------------

/// Scientists whose name labels a law, equation or model in school science,
/// mapped to the concept's usual name. "Boyle P1 V1 = P2 V2" → Boyle's law.
const eponyms = {
  'boyle': "Boyle's law", 'charles': "Charles's law", 'gay-lussac': "Gay-Lussac's law", 'avogadro': "Avogadro's law",
  'graham': "Graham's law", 'dalton': "Dalton's law", 'henry': "Henry's law", 'raoult': "Raoult's law",
  'hess': "Hess's law", 'le chatelier': "Le Chatelier's principle", 'faraday': "Faraday's laws", 'ohm': "Ohm's law",
  'kirchhoff': "Kirchhoff's laws", 'coulomb': "Coulomb's law", 'hooke': "Hooke's law", 'newton': "Newton's laws",
  'kepler': "Kepler's laws", 'pascal': "Pascal's law", 'archimedes': "Archimedes' principle",
  'bernoulli': "Bernoulli's principle", 'snell': "Snell's law", 'bohr': 'Bohr model', 'de broglie': 'de Broglie wavelength',
  'heisenberg': 'Heisenberg uncertainty principle', 'schrodinger': 'Schrödinger equation',
  'schrödinger': 'Schrödinger equation', 'planck': "Planck's equation", 'einstein': 'Mass-energy equivalence',
  'rutherford': 'Rutherford model', 'thomson': 'Thomson model', 'mendeleev': "Mendeleev's periodic table",
  'moseley': "Moseley's law", 'hund': "Hund's rule", 'pauli': 'Pauli exclusion principle', 'aufbau': 'Aufbau principle',
  'arrhenius': 'Arrhenius equation', 'nernst': 'Nernst equation', 'beer-lambert': 'Beer-Lambert law',
  'doppler': 'Doppler effect', 'huygens': "Huygens' principle", 'young': "Young's modulus", 'fleming': "Fleming's rules",
  'lenz': "Lenz's law", 'ampere': "Ampère's law", 'gauss': "Gauss's law", 'joule': "Joule's law", 'stefan': 'Stefan-Boltzmann law',
  'wien': "Wien's law", 'mendel': "Mendel's laws", 'hardy-weinberg': 'Hardy-Weinberg principle', 'pythagoras': 'Pythagorean theorem',
  'euler': "Euler's formula", 'fermat': "Fermat's theorem", 'heron': "Heron's formula", 'brahmagupta': "Brahmagupta's formula",
  'rydberg': 'Rydberg formula', 'balmer': 'Balmer series', 'lyman': 'Lyman series', 'paschen': 'Paschen series',
};

/// Single words that label a formula line without being a concept.
const _formulaLabelWords = {
  'unknown', 'length', 'closed', 'open', 'fall', 'taking', 'subtract', 'add', 'multiply', 'divide', 'put', 'take',
  'let', 'solve', 'shortcut', 'reflected', 'transmitted', 'mass', 'time', 'distance', 'area', 'volume',
  'speed', 'direction', 'total', 'sum', 'average', 'mixing', 'radius', 'example', 'examples', 'answer', 'shape',
  'check', 'given', 'find', 'so', 'hence', 'where', 'here', 'then', 'note', 'uses', 'use', 'result', 'exceptions',
  'exception', 'series', 'constants', 'trick', 'tip', 'remember', 'also', 'thus', 'therefore', 'units', 'unit',
  'common', 'key', 'other', 'lines', 'electrons gained', 'step', 'case',
};

/// "Molality m =", "Mole fraction xA =", "Vapour density =", "Empirical formula:",
/// "Boyle P1 V1 =", "Dilution: M1 V1 = M2 V2" — anywhere in a paragraph (formula
/// sheets come out of PDFs as long runs of short lines).
final _formulaLineRe = RegExp(
  r"(?:^|(?<=[\s.;,]))((?:de |le |van |von )?[A-Z][A-Za-zë'’\-]+(?: [a-z][A-Za-z'’\-]*){0,2})"
  r"(?:\s*\([^)]{1,20}\))?((?:\s*[/A-Za-zα-ωΔµχ%][A-Za-z0-9/]{0,4}){0,4})\s*([:=])",
);

/// Rough subject of a document from its words; chemistry and biology have no
/// graph of their own, so this decides the search word and the AI's context.
String detectTopic(String text) {
  const words = {
    'chemistry': [
      'mol', 'mole', 'moles', 'molar', 'molarity', 'molality', 'oxidation', 'acid', 'acids', 'base', 'bases', 'ph',
      'compound', 'compounds', 'reaction', 'reactions', 'organic', 'orbital', 'orbitals', 'isomer', 'isomers',
      'alkane', 'alkene', 'salt', 'concentration', 'valency', 'electrolysis', 'atom', 'atoms', 'ion', 'ions',
      'periodic', 'element', 'elements', 'bond', 'bonds', 'solution', 'solute', 'solvent',
    ],
    'physics': [
      'force', 'velocity', 'acceleration', 'wave', 'waves', 'sound', 'light', 'energy', 'current', 'voltage',
      'motion', 'momentum', 'frequency', 'wavelength', 'lens', 'mirror', 'refraction', 'gravity', 'pressure',
      'resistance', 'magnetic', 'charge', 'work', 'power',
    ],
    'biology': [
      'cell', 'cells', 'organism', 'organisms', 'tissue', 'tissues', 'gene', 'genes', 'dna', 'photosynthesis',
      'enzyme', 'enzymes', 'species', 'plant', 'plants', 'animal', 'animals', 'blood', 'heart', 'digestion', 'protein',
    ],
    'math': [
      'theorem', 'integral', 'function', 'functions', 'derivative', 'matrix', 'proof', 'polynomial', 'triangle',
      'angle', 'circle', 'equation', 'equations', 'probability', 'series', 'limit', 'vector', 'algebra',
    ],
    'cs': ['algorithm', 'algorithms', 'array', 'complexity', 'program', 'programming', 'recursion', 'sorting', 'tree'],
  };
  final counts = <String, int>{};
  for (final w in normalizeText(text).split(' ')) {
    for (final e in words.entries) {
      if (e.value.contains(w)) counts[e.key] = (counts[e.key] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return 'math';
  return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
}

/// Share of characters that aren't letters or spaces: formulas score high.
double _symbolShare(String s) {
  if (s.isEmpty) return 0;
  final other = s.runes.where((r) {
    final c = String.fromCharCode(r);
    return !RegExp(r'[A-Za-z\s]').hasMatch(c);
  }).length;
  return other / s.length;
}

/// Formulas, chemical formulas ("C4 H10", "Cn H2n+2") or short notes.
bool _formulaish(String s) {
  if (s.contains('=') || s.contains('∝') || s.contains('→') || _symbolShare(s) > 0.25) return true;
  final tokens = s.split(RegExp(r'\s+'));
  if (tokens.length <= 3) return true;
  return tokens.where((t) => RegExp(r'[A-Za-z].*\d|\d.*[A-Za-z]').hasMatch(t)).length * 4 >= tokens.length;
}

/// "Organic" heading on a chemistry sheet → "Organic chemistry".
String _branchName(String name, String topic) =>
    topic == 'chemistry' && const {'organic', 'inorganic', 'physical', 'analytical', 'nuclear'}.contains(name.toLowerCase())
        ? '$name chemistry'
        : name;

/// "Molality", "Mole fraction", "Boyle" + an equation → the concept's name,
/// or null if the label isn't one.
String? formulaConceptName(String rawTerm) {
  var term = rawTerm.trim().replaceAll(RegExp(r'\s+'), ' ');
  final eponym = eponyms[term.toLowerCase()];
  if (eponym != null) return eponym;
  final lower = term.toLowerCase();
  if (_formulaLabelWords.contains(lower) || _formulaLabelWords.contains(lower.split(' ').first)) return null;
  term = term.replaceFirst(RegExp(r'^Avg\b'), 'Average');
  return conceptNameFromTitle(term);
}

class _Section {
  _Section(this.title, this.heading, {this.practice = false});
  final String? title; // heading text without its number; null before the first heading
  final Heading heading;
  final bool practice; // question bank, formula sheet, …: not mined
  final paras = <Paragraph>[];
}

String _stripNumber(String heading) => heading
    .replaceFirst(RegExp(r'^\s*(?:chapter|unit|part)\s+(?:\d+|[ivxlc]+)\b[\s.:–—-]*', caseSensitive: false), '')
    .replaceFirst(RegExp(r'^\s*\d+(?:\.\d+)*\.?\s+'), '')
    .trim();

/// [loose]: also return the weak finds (needsCheck = true) for the on-device AI
/// to verify, plus every known concept mentioned, with its sentence as evidence.
List<ExtractedConcept> extractByRules(List<Paragraph> paragraphs, ConceptDictionary dict,
    {String? subject, String difficulty = 'undergrad', bool loose = false}) {
  final allText = paragraphs.map((p) => p.text).join('\n');
  final topic = detectTopic(allText);
  // The graph knows math, physics and computer science; chemistry and biology
  // concepts are stored as physics (the nearest), and the PDF keeps its own topic.
  final subj = subject ?? (const {'math', 'physics', 'cs'}.contains(topic) ? topic : null) ??
      dict.dominantSubject(allText) ?? 'physics';
  // On a sheet without numbered chapters, the last topic heading is the chapter.
  String? topicChapter;
  late final bool numbered;

  // Group paragraphs by heading (chapter or section).
  final sections = <_Section>[_Section(null, Heading())];
  for (final p in paragraphs) {
    if (p.isHeading) {
      final title = _stripNumber(p.text);
      final inPractice = _practiceSectionRe.hasMatch(title) ||
          // a section inside a practice chapter ("16 Question bank" → "16.1 …")
          (p.heading.section != null && sections.last.practice && sections.last.heading.chapter == p.heading.chapter);
      sections.add(_Section(title, p.heading, practice: inPractice));
      continue;
    }
    sections.last.paras.add(p);
  }

  bool hasSubsections(_Section chapter) => sections.any((s) =>
      s != chapter && s.heading.section != null && s.heading.chapter == chapter.heading.chapter);

  // All teaching text, for "does the notes use this term again?".
  final teachingText = [
    for (final sec in sections)
      if (!sec.practice)
        for (final p in sec.paras) p,
  ];
  bool recurs(String term, Paragraph except) {
    final re = RegExp('\\b${RegExp.escape(normalizeText(term))}s?\\b');
    var n = 0;
    for (final p in teachingText) {
      if (identical(p, except)) continue;
      n += re.allMatches(normalizeText(p.text)).length;
      if (n >= 1) return true;
    }
    return false;
  }

  numbered = sections.any((s) => s.title != null);
  final out = <ExtractedConcept>[];
  final taughtNames = <String>{};
  final teaching = [for (final s in sections) if (!s.practice) s];

  void add(String name, String statement, Paragraph? at, _Section sec,
      {required double importance, String? type, bool sure = true, List<String> prereqs = const []}) {
    final n = name.trim();
    if (!_usableTerm(n)) return;
    if (!sure && !loose) return;
    // Weak finds must at least look like a name, not a clause ("the beam is bent sharply").
    if (!sure && (_sentenceLike(n) || n.split(' ').length > 4 || RegExp(r'^(the|a|an) ', caseSensitive: false).hasMatch(n) && n.split(' ').length > 3)) {
      return;
    }
    out.add(ExtractedConcept(
      name: n,
      type: type ?? dict.typeOf(n) ?? _guessType(n),
      subject: subj,
      statement: _clip(statement),
      chapter: (at?.heading ?? sec.heading).chapter ?? (numbered ? null : topicChapter),
      section: (at?.heading ?? sec.heading).section ?? (at?.heading ?? sec.heading).chapter ??
          (numbered ? null : topicChapter),
      difficulty: difficulty,
      importance: sure ? importance : importance.clamp(0.0, 0.5).toDouble(),
      prerequisitesMentioned: prereqs,
      fromRule: true,
      needsCheck: !sure,
    ));
    if (sure) taughtNames.add(n);
  }

  /// A heading or box title naming two things: "Refraction and dispersion",
  /// "Snell's law and critical angle" → one concept each. Phrases joined inside
  /// a longer name stay whole ("Reflection of light and sound").
  void addTitled(String name, String statement, Paragraph? at, _Section sec,
      {required double importance, bool sure = true, List<String> prereqs = const []}) {
    // "Acids, bases, pH": a list heading, one concept each.
    final listItems = name.split(RegExp(r'\s*,\s*(?:and\s+)?|\s+and\s+(?=[^,]*$)'));
    if (name.contains(',') && listItems.length >= 2 && listItems.length <= 5 &&
        listItems.every((x) => x.trim().length >= 2 && x.trim().split(' ').length <= 3)) {
      for (final item in listItems) {
        add(_cap(item.trim()), statement, at, sec, importance: importance, sure: sure, prereqs: prereqs);
      }
      return;
    }
    final parts = name.split(RegExp(r' and ', caseSensitive: false));
    final splittable = parts.length == 2 &&
        !RegExp(r'\b(of|in|on|between|for|from|to|with|by)\b', caseSensitive: false).hasMatch(name) &&
        parts.every((x) => x.trim().length >= 3 && x.trim().split(' ').length <= 3);
    if (!splittable) {
      add(name, statement, at, sec, importance: importance, sure: sure, prereqs: prereqs);
      return;
    }
    for (final part in parts) {
      add(_cap(part.trim()), statement, at, sec, importance: importance, sure: sure, prereqs: prereqs);
    }
  }

  for (final sec in teaching) {
    final textParas = [for (final p in sec.paras) if (!p.isTitle) p];
    // Statements read better without the box label: "Definition Light is …" → "Light is …".
    final body = textParas.map((p) => p.text.replaceFirst(_labelPrefixRe, '')).join('\n');
    final sentences = _sentences(body);
    final secMentions = dict.mentions(body);

    // 1. The heading names a taught concept (unless it reads like a sentence).
    final title = sec.title?.replaceAll(RegExp(r'[.:]+$'), '').trim();
    final secConcept = title == null || title.isEmpty ? null : conceptNameFromTitle(title);
    if (secConcept != null) {
      final nt = normalizeText(secConcept);
      final head = nt.split(' ').first;
      bool defines(String s) => RegExp(r'\b(is called|is defined|states|we say|means|is a|is the|are)\b').hasMatch(s);
      bool pronounStart(String s) => RegExp(r'^(It|This|That|These|They|So|Here)\b').hasMatch(s);
      bool opensWithTerm(String s) =>
          normalizeText(s.replaceFirst(_bulletRe, '')).replaceFirst(RegExp(r'^(the|a|an) '), '').startsWith(nt) &&
          RegExp(r'\b(is (a|an|the)|is called|is defined|means|refers to)\b').hasMatch(s);
      final defining = sentences.where(opensWithTerm).firstOrNull ??
          sentences.where((s) => normalizeText(s).contains(head) && defines(s) && !pronounStart(s)).firstOrNull ??
          sentences.where((s) => normalizeText(s).contains(head) && defines(s)).firstOrNull ??
          sentences.where((s) => !pronounStart(s)).firstOrNull ??
          (sentences.isEmpty ? title! : sentences.first);
      addTitled(secConcept, defining, null, sec,
          importance: sec.heading.section != null
              ? 0.88
              : hasSubsections(sec)
                  ? 0.6 // a chapter title over numbered sections: the broad topic
                  : 0.85,
          prereqs: [
            for (final e in (secMentions.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
              if (!sameName(e.key, secConcept)) e.key,
          ].take(5).toList());
    }

    for (var i = 0; i < sec.paras.length; i++) {
      final p = sec.paras[i];

      // 3. Box titles: a title line followed by its explanation.
      if (p.isTitle) {
        if (_isBoxLabel(p.text)) continue;
        // What follows, up to the next title line.
        final block = [for (final q in sec.paras.skip(i + 1).takeWhile((q) => !q.isTitle)) q];
        final next = sec.paras.skip(i + 1).where((q) => q.text.trim().length > 3).firstOrNull;
        // 3a. A heading over formulas or short notes (formula sheets, summaries):
        //     "Mole concept", "Gases", "Acids, bases, pH", "Atomic structure".
        // The last of a run of 3+ short labels is a table or diagram cell, not a heading
        // ("Hydrogen / Helium / Air / Oxygen" over a column of numbers).
        final inLabelRun = i >= 2 && sec.paras[i - 1].isTitle && sec.paras[i - 2].isTitle;
        if (!inLabelRun && block.isNotEmpty && (next == null || next.isTitle || next.text.split(' ').length < 6 || _formulaish(next.text)) &&
            block.where((q) => _formulaish(q.text)).length * 2 >= block.length) {
          final raw = p.text.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
          var name = raw.contains(',') ? raw : conceptNameFromTitle(raw);
          if (name != null) name = _branchName(name, topic);
          final eponym = eponyms[raw.toLowerCase().replaceAll(RegExp(r'[:.]$'), '')];
          if (eponym != null) name = eponym;
          if (name != null && !_formulaLabelWords.contains(name.toLowerCase())) {
            if (!numbered && eponym == null) topicChapter = name;
            final statement = _clip(block.take(4).map((q) => q.text).join(' · '), 240);
            final sure = eponym != null || name.contains(' ') || name.contains(',') || block.length >= 2 || dict.knows(name);
            addTitled(name, statement, p, sec, importance: 0.82, sure: sure);
          }
          continue;
        }
        if (next == null || next.isTitle || next.text.split(' ').length < 6) continue;
        var name = conceptNameFromTitle(p.text);
        if (name == null) continue;
        name = _branchName(name, topic);
        final head = normalizeText(name).split(' ').first;
        final explained = normalizeText(next.text).contains(head);
        final sure = name.contains(' ') || dict.knows(name) || explained;
        addTitled(name, _sentences(next.text).take(2).join(' '), next, sec, importance: 0.8, sure: sure);
        continue;
      }

      // 2. Labelled blocks.
      final m = _labelRe.firstMatch(p.text);
      if (m != null && m.group(4) != null && m.group(4)!.trim().length > 10) {
        final kind = m.group(1)!.toLowerCase();
        final named = m.group(3)?.trim();
        final rest = m.group(4)!.trim();
        final subjectTerm = _subjectDefRe.firstMatch(rest)?.group(1);
        // "Definition. Light is a form of energy …" defines Light, not the graph term it mentions.
        final subjectName = subjectTerm != null && _usableTerm(subjectTerm)
            ? dict.mostSpecific(subjectTerm) ?? _cap(subjectTerm)
            : null;
        final name = named ?? subjectName ?? dict.mostSpecific(rest) ?? secConcept;
        if (name != null) {
          add(name, _sentences(rest).take(2).join(' '), p, sec,
              importance: kind == 'lemma' ? 0.5 : 0.9, type: _labelType[kind]);
        }
      }

      // 3b. Named formula lines: "Molality m = …", "Boyle P1 V1 = …", "Dilution: M1 V1 = M2 V2".
      //     Not inside worked examples ("Subtract: 170 = 0.5v" is a step, not a concept).
      final inExample = RegExp(r'\b(Answer|Worked example|Example|Solution|Hint)\b').hasMatch(p.text);
      for (final fm in inExample ? const <RegExpMatch>[] : _formulaLineRe.allMatches(p.text)) {
        // Symbols written after the name aren't part of it: "Mole fraction xA" → "Mole fraction".
        final words = fm.group(1)!.split(' ');
        while (words.length > 1 && RegExp(r'^[a-z]{1,2}[A-Z0-9]|^[a-z]$').hasMatch(words.last)) {
          words.removeLast();
        }
        final raw = words.join(' ');
        // A symbol, not a name: "EF mass moles", "VST P".
        if (words.length > 1 && RegExp(r'^[A-Z]{1,3}$').hasMatch(words.first) && !eponyms.containsKey(raw.toLowerCase())) {
          continue;
        }
        final name = formulaConceptName(raw);
        if (name == null) continue;
        final after = p.text.substring(fm.end, (fm.end + 40).clamp(0, p.text.length));
        final isEq = fm.group(3) == '=' || after.contains('=');
        final eponym = eponyms.containsKey(raw.toLowerCase());
        // "Name:" followed by prose ("Exceptions: Cr …") isn't a formula.
        if (!isEq && !eponym) continue;
        final single = !name.contains(' ');
        final quantityWord = RegExp(r'(ity|ion|ance|ence|ure|ness|ment|ism)$').hasMatch(name.toLowerCase());
        final known = dict.knows(name);
        // In notes with chapters, a lone word before "=" is usually a step or a symbol
        // ("Length = …", "Lopen = 2 Lclosed"); on a formula sheet the AI decides.
        if (numbered && single && !eponym && !quantityWord && !known) continue;
        final statement = p.text.substring(fm.start, (fm.end + 60).clamp(0, p.text.length)).trim();
        add(name, statement, p, sec,
            importance: 0.78,
            type: name.contains(RegExp(r'law|principle|rule')) ? 'theorem' : 'formula',
            sure: isEq && (eponym || !single || quantityWord || known));
      }

      // 4. Lead-in terms: "Brightness — depends on …", "1. Elasticity — when …".
      final unbulleted = p.text.replaceFirst(_bulletRe, '');
      final li = _leadInRe.firstMatch(unbulleted);
      if (li != null && m == null) {
        final term = li.group(1)!.trim();
        final rest = li.group(3)!.trim();
        if (!term.contains(',') && term.split(' ').length <= 4 && !_isBoxLabel(term) &&
            !RegExp(r'^(and|or|but|so|then|if)\b', caseSensitive: false).hasMatch(term)) {
          final sure = RegExp(r'^(depends on|is |are |means|refers to|measures)', caseSensitive: false).hasMatch(rest);
          // A weak one is only proposed if the notes use the term again elsewhere: real
          // concepts recur ("Elasticity", "Nodes"); items in a list of examples ("Bees and
          // mosquitoes — their wings", "Human voice — the vocal cords") don't.
          final pairOfThings = RegExp(r' (and|or) ', caseSensitive: false).hasMatch(term);
          if (sure || (!pairOfThings && (dict.knows(term) || recurs(term, p)))) {
            add(_cap(term), '$term — ${_sentences(rest).first}', p, sec, importance: 0.75, sure: sure);
          }
        }
      }

      // 5. Defining sentences.
      final ss = _sentences(p.text);
      for (var k = 0; k < ss.length; k++) {
        final s = ss[k].replaceFirst(_bulletRe, '');
        final lower = s.toLowerCase();
        for (final (re, sureRe) in _definingRes) {
          for (final dm in re.allMatches(lower)) {
            final term = dm.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ').replaceFirst(RegExp(r'^(the|a|an) '), '');
            final known = dict.mostSpecific(term);
            final sure = sureRe && (known != null || term.contains(' ') || term.contains('-'));
            add(known ?? _titleCase(term), s, p, sec, importance: 0.7, sure: sure);
          }
        }
        final pd = _predicateDefRe.firstMatch(s);
        if (pd != null) {
          final term = pd.group(1)!;
          add(dict.mostSpecific(term) ?? _cap(term), s, p, sec, importance: 0.65, sure: false);
        } else {
          final sd = _subjectDefRe.firstMatch(s);
          if (sd != null) {
            final term = sd.group(1)!;
            final first = term.toLowerCase().split(' ').first;
            if (!_notConcepts.contains(first)) {
              final multi = term.contains(' ');
              // A lone word is confident only when it opens the paragraph or bullet.
              final sure = multi || k == 0 || dict.knows(term);
              add(dict.mostSpecific(term) ?? _cap(term), s, p, sec, importance: 0.7, sure: sure);
            }
          }
        }
        for (final re in [_bracketTermRe, _colonTermRe]) {
          final bm = re.firstMatch(s);
          if (bm != null) add(_cap(bm.group(1)!.trim()), s, p, sec, importance: 0.55, sure: false);
        }
      }
    }

    // 6. Vocabulary lists: three or more title lines in a row, most of them "Name symbol".
    final run = <Paragraph>[];
    void closeRun() {
      final names = [for (final q in run) _glossLineRe.firstMatch(q.text.trim())];
      final withSymbol = names.where((g) => g?.group(2) != null).length;
      if (run.length >= 3 && withSymbol >= run.length / 2) {
        for (var j = 0; j < run.length; j++) {
          final g = names[j];
          final name = g == null ? null : conceptNameFromTitle(run[j].text);
          if (name != null) add(name, run[j].text, run[j], sec, importance: 0.65);
        }
      }
      run.clear();
    }

    for (final q in sec.paras) {
      if (q.text.trim().length <= 3) continue; // a lone symbol between list lines
      if (q.isTitle && _glossLineRe.hasMatch(q.text.trim()) && !_isBoxLabel(q.text)) {
        run.add(q);
      } else {
        closeRun();
      }
    }
    closeRun();
  }

  // A lone word in the same section as a longer name it opens ("Power" from a
  // vocabulary list, "Power of a lens" defined below it) is that longer concept.
  final longer = [for (final e in out) if (e.name.contains(' of ')) (normalizeText(e.name), e.section)];
  out.removeWhere((e) {
    final n = normalizeText(e.name);
    return !n.contains(' ') && longer.any((l) => l.$2 == e.section && l.$1.startsWith('$n of '));
  });

  // 7. Known concepts discussed substantially (≥3 mentions in ≥2 paragraphs, with a
  //    defining sentence) count as taught; other mentions stay prerequisites.
  //    In loose mode every mentioned concept is proposed and the AI decides.
  final taughtNorm = {for (final n in taughtNames) normalizeText(n)};
  final teachParas = [for (final s in teaching) ...s.paras.where((p) => !p.isTitle)];
  final globalMentions = <String, int>{};
  final mentionParas = <String, int>{};
  for (final p in teachParas) {
    dict.mentions(p.text).forEach((k, v) {
      globalMentions[k] = (globalMentions[k] ?? 0) + v;
      mentionParas[k] = (mentionParas[k] ?? 0) + 1;
    });
  }
  // "We assume the product rule", "review the chain rule before starting": named as
  // prerequisites, so frequency alone never makes them taught here.
  final assumedCue = RegExp(
      r'\b(review|recall|we assume|assume[sd]?|you should know|familiar with|prerequisites?|from (the )?(last|previous) chapter|we will (make )?(repeated )?use)\b',
      caseSensitive: false);
  final assumed = <String>{
    for (final p in teachParas)
      for (final s in _sentences(p.text))
        if (assumedCue.hasMatch(s)) ...dict.mentions(s).keys,
  };
  for (final e in globalMentions.entries) {
    final name = e.key;
    final n = normalizeText(name);
    if (taughtNorm.any((t) => sameName(t, n))) continue;
    final mentions = teachParas
        .expand((p) => _sentences(p.text).map((s) => (s, p)))
        .where((x) => RegExp('\\b${RegExp.escape(n)}').hasMatch(normalizeText(x.$1)))
        .toList();
    final defining = mentions
        .where((x) => RegExp(r'\b(states|is called|is defined|says|gives|means)\b').hasMatch(x.$1))
        .firstOrNull;
    // Single generic words ("Function", "Vector", "Limit") are everywhere in maths text;
    // frequency alone doesn't make them the topic. Headings/labels/definitions still can.
    final substantial = e.value >= 3 &&
        (mentionParas[e.key] ?? 0) >= 2 &&
        name.trim().contains(' ') &&
        defining != null &&
        !assumed.contains(name);
    final evidence = defining ?? mentions.firstOrNull;
    if (evidence == null) continue;
    final sec = teaching.firstWhere((s) => s.paras.contains(evidence.$2), orElse: () => teaching.first);
    add(name, evidence.$1, evidence.$2, sec,
        importance: (0.3 + 0.05 * e.value).clamp(0.3, 0.6).toDouble(), sure: substantial);
  }
  return out;
}

/// Same concept name, allowing a plural ("Standing waves" / "Standing wave").
bool sameName(String a, String b) {
  String sing(String s) => normalizeText(s)
      .split(' ')
      .map((w) => w.length > 3 && w.endsWith('s') && !w.endsWith('ss') ? w.substring(0, w.length - 1) : w)
      .join(' ');
  return sing(a) == sing(b);
}
