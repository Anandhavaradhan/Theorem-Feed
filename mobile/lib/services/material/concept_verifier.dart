/// AI check of the doubtful finds, on the device.
///
/// The rules keep confident finds (headings, box titles, "X is called …")
/// without the AI. Only weak ones (a lone word, a phrase in brackets, a
/// passing mention of a known concept) come here. The small local model reads
/// each with the sentence it came from, in batches of 10, and answers with two
/// short lists of numbers:
///
///   taught     → a concept of this material
///   mentioned  → a real concept only mentioned/assumed → prerequisite
///   (neither)  → dropped (generic words, labels, examples of objects, noise)
///
/// Answering with numbers only keeps each call to a few dozen output tokens,
/// so checking 40 candidates takes seconds instead of minutes. If the model
/// fails on a batch, that batch is dropped: the confident finds never depend
/// on the AI.
library;

import '../llm.dart';
import 'concept_extractor.dart';

const verifyBatchSize = 10;

const verifySystemPrompt = '''
You check candidate study concepts found in a student's notes. Answer with JSON only.
"taught": the numbers of candidates that are real math, physics or computer-science concepts, laws, quantities, definitions, formulas or techniques that the evidence explains or defines.
"mentioned": the numbers of real concepts that are only mentioned or assumed known.
Leave out generic words ("speed", "answer", "method"), labels ("Exam trap", "Uses"), everyday objects or examples ("torch", "mirror shop"), adjectives, and fragments.''';

Map<String, Object?> verifySchema(int n) {
  final nums = {'type': 'string', 'enum': [for (var i = 1; i <= n; i++) '$i']};
  return {
    'type': 'object',
    'properties': {
      'taught': {'type': 'array', 'items': nums, 'maxItems': n},
      'mentioned': {'type': 'array', 'items': nums, 'maxItems': n},
    },
    'required': ['taught', 'mentioned'],
    'additionalProperties': false,
  };
}

class VerifyResult {
  VerifyResult({required this.concepts, required this.mentionedOnly, required this.checked, this.error});
  final List<ExtractedConcept> concepts;

  /// Real concepts the notes only mention → prerequisites of their section's concept.
  final List<ExtractedConcept> mentionedOnly;
  final int checked;
  final String? error; // first model failure, if any (that batch was dropped)
}

String _clip(String s, int n) => s.length > n ? '${s.substring(0, n - 1)}…' : s;

Future<VerifyResult> verifyCandidates(
  JsonModel model,
  List<ExtractedConcept> candidates, {
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final kept = <ExtractedConcept>[];
  final mentioned = <ExtractedConcept>[];
  String? error;
  var checked = 0;
  final batches = (candidates.length / verifyBatchSize).ceil();

  for (var b = 0; b < batches; b++) {
    if (isCancelled?.call() ?? false) break;
    final batch = candidates.skip(b * verifyBatchSize).take(verifyBatchSize).toList();
    final prompt = StringBuffer();
    for (var i = 0; i < batch.length; i++) {
      final c = batch[i];
      prompt
        ..writeln('${i + 1}. ${c.name}')
        ..writeln('   evidence: ${_clip(c.statement, 180)}');
    }
    try {
      final json = await model.generateJson(
        system: verifySystemPrompt,
        content: [TextContent(prompt.toString())],
        schema: verifySchema(batch.length),
        maxTokens: 12 * batch.length + 40,
      );
      if (json['taught'] is! List || json['mentioned'] is! List) {
        throw FormatException('expected "taught" and "mentioned" lists, got ${json.keys.join(', ')}');
      }
      Set<int> nums(Object? list) => {
            for (final x in list! as List)
              if (int.tryParse('$x') case final int i when i >= 1 && i <= batch.length) i,
          };
      final taught = nums(json['taught']);
      final ment = nums(json['mentioned'])..removeAll(taught);
      for (final i in taught) {
        kept.add(batch[i - 1].copyWith(needsCheck: false));
      }
      for (final i in ment) {
        mentioned.add(batch[i - 1]);
      }
      checked += batch.length;
    } on ModelApiError catch (e) {
      error ??= e.message;
    } on ModelRefusal catch (e) {
      error ??= '$e';
    } on Object catch (e) {
      error ??= 'unexpected answer: $e';
    }
    onProgress?.call(b + 1, batches);
  }
  return VerifyResult(concepts: kept, mentionedOnly: mentioned, checked: checked, error: error);
}
