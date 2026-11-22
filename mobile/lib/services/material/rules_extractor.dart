/// Fast, rules-first concept extraction for clear, text-based PDFs. No AI
/// needed; runs in milliseconds.
///
/// What a well-made textbook tells us, strongest signal first:
///   1. Section headings          "7.1 Integration by Parts"      → taught concept
///   2. Labelled blocks           "Theorem 7.1 (Mean Value Theorem). …" / "Definition 7.4. …"
///   3. Defining phrases          "… is called integration by parts."
///   4. Known concept names       every name/alias in the knowledge graph, counted
///
/// Concepts only mentioned in passing ("review the product rule") are not
/// treated as taught; they become prerequisites of the section's concept.
library;

import '../text_match.dart';
import 'concept_extractor.dart';
import 'text_pipeline.dart';

/// Names and aliases of known concepts (the graph plus anything created before).
class ConceptDictionary {
  ConceptDictionary(Iterable<(String name, List<String> aliases, String type)> concepts) {
    for (final (name, aliases, type) in concepts) {
      _types[name] = type;
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

  String? typeOf(String name) => _types[name];

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

const _headingStopwords = {
  'exercises', 'exercise', 'problems', 'problem set', 'summary', 'review', 'chapter review', 'introduction',
  'overview', 'examples', 'example', 'notes', 'references', 'appendix', 'contents', 'preface', 'solutions',
  'answers', 'key terms', 'objectives', 'learning objectives', 'conclusion', 'further reading', 'questions',
  'practice', 'homework', 'review questions', 'bibliography', 'index',
};

final _labelRe = RegExp(
  r'^(Theorem|Lemma|Proposition|Corollary|Definition|Formula|Law|Principle|Rule|Algorithm|Identity)'
  r'\s*(\d+(?:\.\d+)*)?\s*(?:\(([^)]{3,80})\))?\s*[.:]?\s*(.*)$',
  caseSensitive: false,
  dotAll: true,
);

const _labelType = {
  'theorem': 'theorem', 'lemma': 'theorem', 'proposition': 'theorem', 'corollary': 'theorem',
  'law': 'theorem', 'principle': 'theorem', 'identity': 'formula', 'definition': 'definition',
  'formula': 'formula', 'rule': 'technique', 'algorithm': 'technique',
};

final _definingRes = [
  RegExp(r'\b(?:is|are) called (?:an? |the )?([a-z][a-z\- ]{2,50}?)(?=[.,;:]| if\b| when\b| and\b| for\b|$)'),
  RegExp(r'\b(?:is|are) known as (?:an? |the )?([a-z][a-z\- ]{2,50}?)(?=[.,;:]|$)'),
  RegExp(r'\b(?:is|are) said to be (?:an? )?([a-z][a-z\- ]{2,50}?)(?=[.,;:]|$)'),
  RegExp(r'\bwe call (?:this|it|such \w+|them) (?:an? |the )?([a-z][a-z\- ]{2,50}?)(?=[.,;:]|$)'),
];

final _sentenceSplit = RegExp(r'(?<=[.!?])\s+(?=[A-Z0-9])');

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
  if (RegExp(r'\b(theorem|lemma|law|principle|inequality|identity)\b').hasMatch(n)) return 'theorem';
  if (RegExp(r'\b(formula|equation)\b').hasMatch(n)) return 'formula';
  if (RegExp(r'\b(method|rule|test|substitution|algorithm|technique|integration by|decomposition)\b').hasMatch(n)) {
    return 'technique';
  }
  return 'concept';
}

class _Section {
  _Section(this.title, this.heading);
  final String? title; // null before the first numbered section
  final Heading heading;
  final paras = <Paragraph>[];
}

List<ExtractedConcept> extractByRules(List<Paragraph> paragraphs, ConceptDictionary dict,
    {String subject = 'math', String difficulty = 'undergrad'}) {
  // Group paragraphs by section.
  final sections = <_Section>[_Section(null, Heading())];
  for (final p in paragraphs) {
    if (p.isHeading && p.heading.section != null && p.heading.section != sections.last.heading.section) {
      final title = p.heading.section!.replaceFirst(RegExp(r'^\d+(\.\d+)*\s+'), '').trim();
      sections.add(_Section(title, p.heading));
      continue;
    }
    if (p.isHeading) continue;
    sections.last.paras.add(p);
  }

  final out = <ExtractedConcept>[];
  final globalMentions = <String, int>{};
  final mentionParas = <String, int>{};
  for (final p in paragraphs.where((p) => !p.isHeading)) {
    final m = dict.mentions(p.text);
    m.forEach((k, v) {
      globalMentions[k] = (globalMentions[k] ?? 0) + v;
      mentionParas[k] = (mentionParas[k] ?? 0) + 1;
    });
  }
  final taughtNames = <String>{};

  for (final sec in sections) {
    final body = sec.paras.map((p) => p.text).join('\n');
    final sentences = _sentences(body);
    final secMentions = dict.mentions(body);

    // 1. The section heading names a taught concept.
    String? secConcept;
    final title = sec.title?.replaceAll(RegExp(r'[.:]+$'), '').trim();
    if (title != null && title.isNotEmpty && !_headingStopwords.contains(title.toLowerCase()) &&
        title.split(' ').length <= 8) {
      secConcept = title;
      final nt = normalizeText(title);
      final defining = sentences.firstWhere(
        (s) => normalizeText(s).contains(nt.split(' ').first) &&
            RegExp(r'\b(is called|is defined|states|we say|means|is a|is the|are)\b').hasMatch(s),
        orElse: () => sentences.isEmpty ? title : sentences.first,
      );
      out.add(ExtractedConcept(
        name: title,
        type: dict.typeOf(title) ?? _guessType(title),
        subject: subject,
        statement: _clip(defining),
        chapter: sec.heading.chapter,
        section: sec.heading.section,
        difficulty: difficulty,
        importance: 0.88,
        prerequisitesMentioned: [
          for (final e in (secMentions.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
            if (normalizeText(e.key) != nt) e.key,
        ].take(5).toList(),
        fromRule: true,
      ));
      taughtNames.add(title);
    }

    for (final p in sec.paras) {
      // 2. Labelled blocks.
      final m = _labelRe.firstMatch(p.text);
      if (m != null && m.group(4) != null && m.group(4)!.trim().length > 10) {
        final kind = m.group(1)!.toLowerCase();
        final named = m.group(3)?.trim();
        final rest = m.group(4)!.trim();
        final name = named ?? dict.mostSpecific(rest) ?? secConcept;
        if (name != null) {
          out.add(ExtractedConcept(
            name: name,
            type: _labelType[kind]!,
            subject: subject,
            statement: _clip(_sentences(rest).take(2).join(' ')),
            chapter: p.heading.chapter,
            section: p.heading.section,
            difficulty: difficulty,
            importance: kind == 'lemma' ? 0.5 : 0.9,
            fromRule: true,
          ));
          taughtNames.add(name);
        }
      }

      // 3. Defining phrases: "… is called integration by parts."
      for (final s in _sentences(p.text)) {
        for (final re in _definingRes) {
          for (final dm in re.allMatches(s.toLowerCase())) {
            var term = dm.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ');
            term = term.replaceFirst(RegExp(r'^(the|a|an) '), '');
            final known = dict.mostSpecific(term);
            // Single words ("proper") are adjectives, not concepts, unless the graph knows them.
            if (known == null && term.split(' ').length < 2) continue;
            final name = known ?? _titleCase(term);
            out.add(ExtractedConcept(
              name: name,
              type: dict.typeOf(name) ?? _guessType(name),
              subject: subject,
              statement: _clip(s),
              chapter: p.heading.chapter,
              section: p.heading.section,
              difficulty: difficulty,
              importance: 0.7,
              fromRule: true,
            ));
            taughtNames.add(name);
          }
        }
      }
    }
  }

  // 4. Known concepts discussed substantially (≥3 mentions in ≥2 paragraphs, with a
  //    defining sentence) count as taught; other mentions stay prerequisites.
  for (final e in globalMentions.entries) {
    if (taughtNames.contains(e.key) || e.value < 3 || (mentionParas[e.key] ?? 0) < 2) continue;
    // Single generic words ("Function", "Vector", "Limit") are everywhere in maths text;
    // frequency alone doesn't make them the topic. Headings/labels/definitions still can.
    if (!e.key.trim().contains(' ')) continue;
    final name = e.key;
    final n = normalizeText(name);
    final defining = paragraphs
        .expand((p) => _sentences(p.text).map((s) => (s, p)))
        .where((x) => normalizeText(x.$1).contains(n) &&
            RegExp(r'\b(states|is called|is defined|says|gives|means)\b').hasMatch(x.$1))
        .firstOrNull;
    if (defining == null) continue;
    out.add(ExtractedConcept(
      name: name,
      type: dict.typeOf(name) ?? _guessType(name),
      subject: subject,
      statement: _clip(defining.$1),
      chapter: defining.$2.heading.chapter,
      section: defining.$2.heading.section,
      difficulty: difficulty,
      importance: (0.3 + 0.05 * e.value).clamp(0.3, 0.6).toDouble(),
      fromRule: true,
    ));
  }
  return out;
}
