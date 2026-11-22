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

/// Plays a small local model: keeps real concepts, drops generic words, marks
/// passing mentions as not taught, tidies names.
class FakeVerifier implements JsonModel {
  int calls = 0;
  final seen = <String>[];
  Object? failWith;
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
      required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async {
    calls++;
    expect(system, verifySystemPrompt);
    if (failWith != null) throw failWith!;
    final text = (content.single as TextContent).text;
    final items = <Map<String, Object?>>[];
    for (final m in RegExp(r'^\[(\d+)\] candidate: (.*)$', multiLine: true).allMatches(text)) {
      final name = m.group(2)!;
      seen.add(name);
      final lower = name.toLowerCase();
      final generic = const {'function', 'integral', 'derivative', 'polynomial', 'proper'}.contains(lower);
      final mentioned = const {'product rule', 'fundamental theorem of calculus', 'pythagorean identity'}.contains(lower);
      items.add({
        'n': m.group(1),
        'keep': !generic,
        'taught': !mentioned,
        'name': lower == 'improper integrals' ? 'Improper Integral' : name,
        'type': 'concept',
      });
    }
    return {'items': items};
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

  test('loose rules + AI verification: real concepts kept, noise dropped, mentions → prerequisites', () async {
    final model = FakeVerifier();
    final svc = MaterialService(db, pdf: _Pdf(), model: model);
    final r = await svc.upload(pdf.path);
    final names = {for (final c in svc.conceptsOf(r.materialId)) c.name};

    expect(r.aiVerified, isTrue);
    expect(r.candidatesChecked, greaterThan(r.ruleConcepts)); // loose rules proposed more than strict ones
    expect(model.calls, (r.candidatesChecked / verifyBatchSize).ceil());
    expect(model.seen, contains('Function')); // generic words are proposed…
    expect(names, isNot(contains('Function'))); // …and rejected by the AI
    expect(names, containsAll(['Integration by Parts', 'Partial Fractions', 'Trigonometric Substitution', 'Improper Integral']));
    expect(names, isNot(contains('Product Rule'))); // only mentioned in this chapter
    final prereqs = db.select('''
      SELECT p.canonical_name FROM material_concepts mc JOIN concepts c ON c.id = mc.concept_id,
           json_each(mc.prerequisites_mentioned) j JOIN concepts p ON p.id = j.value
      WHERE c.canonical_name = 'Integration by Parts' ''').map((x) => x['canonical_name']).toSet();
    expect(prereqs, contains('Product Rule'));
  });

  test('if the AI fails, the strict rules decide: never zero concepts because of the AI', () async {
    final model = FakeVerifier()..failWith = ModelApiError(0, 'local_model', 'out of memory');
    final svc = MaterialService(db, pdf: _Pdf(), model: model);
    final r = await svc.upload(pdf.path);
    expect(r.aiError, 'out of memory');
    expect(r.conceptCount, greaterThanOrEqualTo(5));
    expect({for (final c in svc.conceptsOf(r.materialId)) c.name},
        containsAll(['Integration by Parts', 'Partial Fractions', 'Improper Integral']));
  });

  test('malformed AI answers fall back too', () async {
    final svc = MaterialService(db, pdf: _Pdf(), model: _Garbage());
    final r = await svc.upload(pdf.path);
    expect(r.aiError, isNotNull);
    expect(r.conceptCount, greaterThanOrEqualTo(5));
  });
}

class _Garbage implements JsonModel {
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
          required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async =>
      {'concepts': <Object>[]}; // wrong shape
}
