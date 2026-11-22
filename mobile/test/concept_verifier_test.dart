import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/graph_seed.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/material/concept_verifier.dart';
import 'package:theoremfeed/services/material/material_service.dart';
import 'package:theoremfeed/services/material/pdf_text.dart';

import 'support/real_pdf_pages.dart';

class _Pdf implements PdfTextSource {
  @override
  Future<List<String>> pages(String filePath) async => realPdfPages;
}

/// Plays a small local model: answers with candidate numbers only. Keeps real
/// concepts, marks passing mentions, leaves out generic words.
class FakeVerifier implements JsonModel {
  int calls = 0;
  final seen = <String>[];
  final maxTokens = <int>[];
  Object? failWith;
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
      required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async {
    calls++;
    this.maxTokens.add(maxTokens);
    expect(system, verifySystemPrompt);
    if (failWith != null) throw failWith!;
    final text = (content.single as TextContent).text;
    final taught = <String>[], mentioned = <String>[];
    for (final m in RegExp(r'^(\d+)\. (.*)$', multiLine: true).allMatches(text)) {
      final name = m.group(2)!;
      seen.add(name);
      final lower = name.toLowerCase();
      if (const {'function', 'integral', 'derivative', 'polynomial', 'proper'}.contains(lower)) continue;
      if (const {'product rule', 'fundamental theorem of calculus', 'pythagorean identity'}.contains(lower)) {
        mentioned.add(m.group(1)!);
      } else {
        taught.add(m.group(1)!);
      }
    }
    return {'taught': taught, 'mentioned': mentioned};
  }
}

void main() {
  late AppDatabase db;
  late File pdf;
  setUp(() {
    db = AppDatabase.inMemory();
    loadGraphSeed(db, File(graphSeedAsset).readAsStringSync());
    pdf = File('${Directory.systemTemp.createTempSync('tf').path}/Ch7.pdf')..writeAsStringSync('x');
  });

  const confident = ['Integration by Parts', 'Trigonometric Substitution', 'Partial Fractions', 'Improper Integral'];

  test('only doubtful finds go to the AI; it keeps real ones, drops noise, mentions → prerequisites', () async {
    final model = FakeVerifier();
    final svc = MaterialService(db, pdf: _Pdf(), model: model);
    final r = await svc.upload(pdf.path);
    final names = {for (final c in svc.conceptsOf(r.materialId)) c.name};

    expect(r.aiVerified, isTrue);
    expect(r.candidatesChecked, greaterThan(0));
    expect(model.calls, (r.candidatesChecked / verifyBatchSize).ceil());
    // Confident finds are never sent to the model…
    expect(model.seen.toSet().intersection(confident.toSet()), isEmpty);
    expect(names, containsAll(confident));
    // …weak ones are: generic words are proposed and dropped, real ones kept.
    expect(model.seen, contains('Function'));
    expect(names, isNot(contains('Function')));
    expect(model.seen, contains('Double Angle Formulas'));
    expect(names, contains('Double Angle Formulas'));
    expect(names, isNot(contains('Product Rule'))); // only mentioned in this chapter
    final prereqs = db.select('''
      SELECT p.canonical_name FROM material_concepts mc JOIN concepts c ON c.id = mc.concept_id,
           json_each(mc.prerequisites_mentioned) j JOIN concepts p ON p.id = j.value
      WHERE c.canonical_name = 'Integration by Parts' ''').map((x) => x['canonical_name']).toSet();
    expect(prereqs, contains('Product Rule'));
    // Answers are lists of numbers: a few output tokens per candidate.
    expect(model.maxTokens.every((t) => t <= 12 * verifyBatchSize + 40), isTrue);
  });

  test('if the AI fails, the confident finds stand: never zero concepts because of the AI', () async {
    final model = FakeVerifier()..failWith = ModelApiError(0, 'local_model', 'out of memory');
    final svc = MaterialService(db, pdf: _Pdf(), model: model);
    final r = await svc.upload(pdf.path);
    expect(r.aiError, 'out of memory');
    expect({for (final c in svc.conceptsOf(r.materialId)) c.name}, containsAll(confident));
  });

  test('malformed AI answers are reported and change nothing', () async {
    final svc = MaterialService(db, pdf: _Pdf(), model: _Garbage());
    final r = await svc.upload(pdf.path);
    expect(r.aiError, isNotNull);
    expect({for (final c in svc.conceptsOf(r.materialId)) c.name}, containsAll(confident));
  });
}

class _Garbage implements JsonModel {
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
          required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async =>
      {'concepts': <Object>[]}; // wrong shape
}
