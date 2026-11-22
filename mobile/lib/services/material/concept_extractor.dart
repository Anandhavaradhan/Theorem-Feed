/// Concept extraction from a cleaned chunk (§6.3), on the device.
///
/// Two sources, merged:
///   1. Rules: clear PDFs label their results ("Theorem 7.1 (Integration by
///      Parts). If u and v are…"). Labelled, named blocks are read exactly.
///   2. The on-device model, with the §6.3 prompt (shortened for a small model)
///      and a JSON schema enforced during decoding.
library;

import '../llm.dart';
import 'text_pipeline.dart';

const conceptTypes = ['theorem', 'definition', 'formula', 'technique', 'concept'];
const difficulties = ['highschool', 'undergrad', 'advanced'];

class ExtractedConcept {
  ExtractedConcept({
    required this.name,
    required this.type,
    required this.subject,
    required this.statement,
    this.latex,
    this.chapter,
    this.section,
    required this.difficulty,
    this.prerequisitesMentioned = const [],
    required this.importance,
    this.fromRule = false,
    this.needsCheck = false,
  });

  final String name;
  final String type;
  final String subject; // math | physics | cs
  final String statement;
  final String? latex;
  final String? chapter;
  final String? section;
  final String difficulty;
  final List<String> prerequisitesMentioned;
  final double importance; // 0..1
  final bool fromRule;

  /// Found by a weak rule (a lone word, a passing mention): the on-device AI
  /// decides. Confident finds (headings, box titles, "X is called …") skip it.
  final bool needsCheck;

  ExtractedConcept copyWith({double? importance, List<String>? prerequisitesMentioned, String? latex, bool? needsCheck}) =>
      ExtractedConcept(
        name: name,
        type: type,
        subject: subject,
        statement: statement,
        latex: latex ?? this.latex,
        chapter: chapter,
        section: section,
        difficulty: difficulty,
        prerequisitesMentioned: prerequisitesMentioned ?? this.prerequisitesMentioned,
        importance: importance ?? this.importance,
        fromRule: fromRule,
        needsCheck: needsCheck ?? this.needsCheck,
      );
}

// --- 1. Rules -----------------------------------------------------------------

final _labelled = RegExp(
  r'^(Theorem|Lemma|Proposition|Corollary|Definition|Formula|Law|Principle|Rule|Algorithm|Identity)'
  r'\s*(\d+(?:\.\d+)*)?\s*\(([^)]{3,80})\)\s*[.:]\s*(.+)$',
  dotAll: true,
);

const _labelType = {
  'theorem': 'theorem', 'lemma': 'theorem', 'proposition': 'theorem', 'corollary': 'theorem',
  'law': 'theorem', 'principle': 'theorem', 'identity': 'formula', 'definition': 'definition',
  'formula': 'formula', 'rule': 'technique', 'algorithm': 'technique',
};

/// Named, labelled blocks in a chunk: "Theorem 7.1 (Integration by Parts). …".
List<ExtractedConcept> extractLabelled(Chunk chunk, {String subject = 'math', String difficulty = 'undergrad'}) {
  final out = <ExtractedConcept>[];
  final paras = chunk.paragraphs.isNotEmpty
      ? chunk.paragraphs
      : [for (final t in chunk.text.split(RegExp(r'\n\s*\n'))) Paragraph(t, chunk.firstPage, Heading(chapter: chunk.chapter, section: chunk.section))];
  for (final para in paras) {
    final m = _labelled.firstMatch(para.text.trim());
    if (m == null) continue;
    var statement = m.group(4)!.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (statement.length > 400) statement = '${statement.substring(0, 397)}...';
    out.add(ExtractedConcept(
      name: m.group(3)!.trim(),
      type: _labelType[m.group(1)!.toLowerCase()]!,
      subject: subject,
      statement: statement,
      chapter: para.heading.chapter ?? chunk.chapter,
      section: para.heading.section ?? chunk.section,
      difficulty: difficulty,
      importance: m.group(1)!.toLowerCase() == 'lemma' ? 0.5 : 0.8,
      fromRule: true,
    ));
  }
  return out;
}

// --- 2. On-device model (§6.3) -------------------------------------------------

const extractionSystemPrompt = '''
You extract study concepts from a math, physics or computer science textbook chunk. Answer with JSON only.
Include every concept, theorem, definition and formula the chunk EXPLICITLY defines, states, proves or teaches. Skip concepts that are only referenced ("as we saw in Chapter 3"), assumed, or mentioned in passing.
name: the canonical English academic term.
statement: one specific sentence saying what it IS in this text's framing (for a theorem, the statement; for a technique, what it does; for a definition, the definition). "Integration by Parts" alone is not enough; write "∫ u dv = uv − ∫ v du, a technique for integrating products of functions".
latex: the formula in LaTeX, or "" if none.
prerequisites_mentioned: concepts the chunk assumes the reader already knows.
importance: 0.9 if it is the main topic of the chunk, 0.3 for a minor definition used in passing.
Return {"concepts": []} if there are none.''';

const extractionSchema = {
  'type': 'object',
  'properties': {
    'concepts': {
      'type': 'array',
      'maxItems': 12,
      'items': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'type': {'type': 'string', 'enum': conceptTypes},
          'subject': {'type': 'string', 'enum': ['math', 'physics', 'cs']},
          'statement': {'type': 'string'},
          'latex': {'type': 'string'},
          'difficulty': {'type': 'string', 'enum': difficulties},
          'prerequisites_mentioned': {'type': 'array', 'maxItems': 6, 'items': {'type': 'string'}},
          'importance': {'type': 'number'},
        },
        'required': ['name', 'type', 'subject', 'statement', 'latex', 'difficulty', 'prerequisites_mentioned', 'importance'],
        'additionalProperties': false,
      },
    },
  },
  'required': ['concepts'],
  'additionalProperties': false,
};

Future<List<ExtractedConcept>> extractWithModel(JsonModel model, Chunk chunk) async {
  final json = await model.generateJson(
    system: extractionSystemPrompt,
    content: [
      TextContent('CHUNK (pages ${chunk.firstPage}-${chunk.lastPage}'
          '${chunk.chapter != null ? ', chapter ${chunk.chapter}' : ''}'
          '${chunk.section != null ? ', section ${chunk.section}' : ''}):\n${chunk.text}'),
    ],
    schema: extractionSchema,
    maxTokens: 1200,
  );
  return [
    for (final c in (json['concepts'] as List).cast<Map<String, dynamic>>())
      if ((c['name'] as String).trim().length >= 3 && (c['statement'] as String).trim().isNotEmpty)
        ExtractedConcept(
          name: (c['name'] as String).trim(),
          type: c['type'] as String,
          subject: c['subject'] as String,
          statement: (c['statement'] as String).trim(),
          latex: (c['latex'] as String).trim().isEmpty ? null : (c['latex'] as String).trim(),
          chapter: chunk.headingFor((c['name'] as String).trim()).chapter ?? chunk.chapter,
          section: chunk.headingFor((c['name'] as String).trim()).section ?? chunk.section,
          difficulty: c['difficulty'] as String,
          prerequisitesMentioned: (c['prerequisites_mentioned'] as List).cast<String>(),
          importance: ((c['importance'] as num).toDouble()).clamp(0.0, 1.0),
        ),
  ];
}
