/// AI verification of rule-proposed concepts, on the device.
///
/// The loose rules propose generously (headings, labelled blocks, "is called"
/// phrases, every known concept mentioned); the small local model then checks
/// each candidate against the sentence it came from, in batches of 8, which
/// is far faster than having it read the whole PDF.
///
///   keep + taught   → a concept of this material
///   keep + !taught  → a real concept only mentioned/assumed → prerequisite
///   !keep           → dropped (generic words, chapter titles, noise)
///
/// If the model fails on a batch, that batch falls back to the strict rules,
/// so an upload never ends with zero concepts because of the AI.
library;

import '../llm.dart';
import 'concept_extractor.dart';
import '../text_match.dart';

const verifyBatchSize = 8;

const verifySystemPrompt = '''
You check candidate study concepts that were found in a textbook chapter. Answer with JSON only.
For each numbered candidate:
keep: true only if it is a real math, physics or computer-science concept, theorem, definition, formula or technique. False for generic words ("function", "example", "method"), section labels ("Exercises", "Review"), chapter titles that are just broad topics, and fragments.
taught: true if the evidence shows the chapter explains, defines, states, proves or works through it; false if it is only mentioned, referenced or assumed known.
name: its standard English textbook name, singular, in Title Case (for example "Integration by Parts", "Improper Integral").
type: theorem, definition, formula, technique or concept.''';

Map<String, Object?> verifySchema(int n) => {
      'type': 'object',
      'properties': {
        'items': {
          'type': 'array',
          'maxItems': n,
          'items': {
            'type': 'object',
            'properties': {
              'n': {'type': 'string', 'enum': [for (var i = 1; i <= n; i++) '$i']},
              'keep': {'type': 'boolean'},
              'taught': {'type': 'boolean'},
              'name': {'type': 'string'},
              'type': {'type': 'string', 'enum': conceptTypes},
            },
            'required': ['n', 'keep', 'taught', 'name', 'type'],
            'additionalProperties': false,
          },
        },
      },
      'required': ['items'],
      'additionalProperties': false,
    };

class VerifyResult {
  VerifyResult({required this.concepts, required this.mentionedOnly, required this.checked, this.error});
  final List<ExtractedConcept> concepts;

  /// Real concepts the chapter only mentions → prerequisites of its section's concept.
  final List<ExtractedConcept> mentionedOnly;
  final int checked;
  final String? error; // first model failure, if any (that batch used the strict rules)
}

String _clip(String s, int n) => s.length > n ? '${s.substring(0, n - 1)}…' : s;

Future<VerifyResult> verifyCandidates(
  JsonModel model,
  List<ExtractedConcept> candidates, {
  required Set<String> strictNames, // what the strict rules alone would keep (fallback)
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final kept = <ExtractedConcept>[];
  final mentioned = <ExtractedConcept>[];
  String? error;
  final strict = {for (final n in strictNames) normalizeText(n)};
  final batches = (candidates.length / verifyBatchSize).ceil();

  for (var b = 0; b < batches; b++) {
    if (isCancelled?.call() ?? false) break;
    final batch = candidates.skip(b * verifyBatchSize).take(verifyBatchSize).toList();
    final prompt = StringBuffer();
    for (var i = 0; i < batch.length; i++) {
      final c = batch[i];
      prompt
        ..writeln('[${i + 1}] candidate: ${c.name}')
        ..writeln('    section: ${c.section ?? c.chapter ?? 'unknown'}')
        ..writeln('    evidence: ${_clip(c.statement, 260)}');
    }
    try {
      final json = await model.generateJson(
        system: verifySystemPrompt,
        content: [TextContent(prompt.toString())],
        schema: verifySchema(batch.length),
        maxTokens: 60 * batch.length + 40,
      );
      final answered = <int>{};
      for (final it in (json['items'] as List).cast<Map<String, dynamic>>()) {
        final i = int.tryParse('${it['n']}');
        if (i == null || i < 1 || i > batch.length || !answered.add(i)) continue;
        final c = batch[i - 1];
        if (it['keep'] != true) continue;
        final cleaned = (it['name'] as String).trim();
        // Accept the model's tidier name only if it still refers to the same thing.
        final name = cleaned.length >= 3 && tokenSetRatio(cleaned, c.name) >= 70 ? cleaned : c.name;
        final v = ExtractedConcept(
          name: name,
          type: it['type'] as String,
          subject: c.subject,
          statement: c.statement,
          latex: c.latex,
          chapter: c.chapter,
          section: c.section,
          difficulty: c.difficulty,
          prerequisitesMentioned: c.prerequisitesMentioned,
          importance: c.importance,
          fromRule: true,
        );
        (it['taught'] == true ? kept : mentioned).add(v);
      }
      // Candidates the model skipped: keep them only if the strict rules would.
      for (var i = 1; i <= batch.length; i++) {
        if (!answered.contains(i) && strict.contains(normalizeText(batch[i - 1].name))) kept.add(batch[i - 1]);
      }
    } on ModelApiError catch (e) {
      error ??= e.message;
      kept.addAll(batch.where((c) => strict.contains(normalizeText(c.name))));
    } on ModelRefusal catch (e) {
      error ??= '$e';
      kept.addAll(batch.where((c) => strict.contains(normalizeText(c.name))));
    } on Object catch (e) {
      // Malformed answer: same fallback.
      error ??= 'unexpected answer: $e';
      kept.addAll(batch.where((c) => strict.contains(normalizeText(c.name))));
    }
    onProgress?.call(b + 1, batches);
  }
  return VerifyResult(concepts: kept, mentionedOnly: mentioned, checked: candidates.length, error: error);
}
