import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/feed_service.dart';
import 'package:theoremfeed/services/graph_seed.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/material/concept_extractor.dart';
import 'package:theoremfeed/services/material/material_service.dart';
import 'package:theoremfeed/services/material/pdf_text.dart';

import 'support/factories.dart';
import 'support/sample_chapter.dart';

class FakePdf implements PdfTextSource {
  FakePdf(this.result);
  final List<String> result;
  @override
  Future<List<String>> pages(String filePath) async => result;
}

/// Answers like a small model would for the sample chapter's chunks.
class FakeExtractor implements JsonModel {
  int calls = 0;
  bool failAll = false;
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
      required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async {
    calls++;
    expect(system, extractionSystemPrompt);
    if (failAll) throw ModelApiError(0, 'local_model', 'boom');
    final text = (content.single as TextContent).text;
    final out = <Map<String, Object?>>[];
    if (text.contains('Theorem 7.1')) {
      out.add({'name': 'Integration by parts', 'type': 'technique', 'subject': 'math',
        'statement': 'A way to integrate products.', 'latex': r'\int u\,dv = uv - \int v\,du', 'difficulty': 'undergrad',
        'prerequisites_mentioned': ['Product Rule', 'Fundamental Theorem of Calculus'], 'importance': 0.9});
      out.add({'name': 'LIATE Rule', 'type': 'technique', 'subject': 'math',
        'statement': 'Heuristic for choosing u in integration by parts.', 'latex': '', 'difficulty': 'undergrad',
        'prerequisites_mentioned': ['Integration by Parts'], 'importance': 0.4});
    }
    if (text.contains('Trigonometric Substitution')) {
      out.add({'name': 'Trigonometric Substitution', 'type': 'technique', 'subject': 'math',
        'statement': 'Substitute x = a sin θ for integrals with √(a² − x²).', 'latex': '', 'difficulty': 'undergrad',
        'prerequisites_mentioned': ['Pythagorean Identity'], 'importance': 0.8});
    }
    return {'concepts': out};
  }
}

void main() {
  late AppDatabase db;
  late File pdf;
  late FakeExtractor model;

  setUp(() {
    db = AppDatabase.inMemory();
    loadGraphSeed(db, File('assets/graph/graph_seed_v1.json').readAsStringSync());
    final dir = Directory.systemTemp.createTempSync('tf');
    pdf = File('${dir.path}/Calculus Ch7.pdf')..writeAsStringSync('%PDF fake ${DateTime.now().microsecondsSinceEpoch}');
    model = FakeExtractor();
  });

  // These tests exercise the AI path, so deep read is on.
  MaterialService svc({List<String> pages = sampleChapterPages, JsonModel? m}) =>
      MaterialService(db, pdf: FakePdf(pages), model: m ?? model, deepRead: true);
  String id(String name) => db.select('SELECT id FROM concepts WHERE canonical_name = ?', [name]).first['id'] as String;
  Map<String, Object?> mc(String materialId, String name) => db.select(
      'SELECT mc.* FROM material_concepts mc JOIN concepts c ON c.id = mc.concept_id '
      'WHERE mc.material_id = ? AND c.canonical_name = ?', [materialId, name]).single;

  test('upload: rules + model → mapped to the graph, new concepts created, feed activates', () async {
    final stages = <UploadStage>{};
    final r = await svc().upload(pdf.path, onProgress: (s, d, t) => stages.add(s));
    expect(stages, UploadStage.values.toSet());
    expect(r.title, 'Calculus Ch7');

    final names = {for (final row in svc().conceptsOf(r.materialId)) row.name};
    expect(names, containsAll(['Integration by Parts', 'Partial Fractions', 'Trigonometric Substitution', 'LIATE Rule']));
    expect(names.length, 4); // the model's "Integration by parts" merged with the rule hit

    // Rule statement (as the material states it) + model LaTeX/prereqs + chapter/section from headings.
    final ibp = mc(r.materialId, 'Integration by Parts');
    expect(ibp['statement'], 'If u and v are differentiable functions, then ∫ u dv = uv − ∫ v du.');
    expect(ibp['latex'], r'\int u\,dv = uv - \int v\,du');
    expect(ibp['chapter'], '7 Techniques of Integration');
    expect(ibp['section'], '7.1 Integration by Parts');
    expect(parseJsonList(ibp['prerequisites_mentioned'] as String),
        containsAll([id('Product Rule'), id('Fundamental Theorem of Calculus')]));

    // "Partial Fraction Decomposition" (rule) mapped onto the graph's "Partial Fractions" via its alias.
    expect(mc(r.materialId, 'Partial Fractions')['statement'], startsWith('A proper rational function'));

    // New concept created with a prerequisite edge into the graph.
    final liate = id('LIATE Rule');
    expect(db.select("SELECT 1 FROM concept_edges WHERE from_concept = ? AND to_concept = ? AND relation = 'requires'",
        [liate, id('Integration by Parts')]), hasLength(1));

    // Active concepts → long-form feed is no longer the upload state; gaps listed, most important first.
    final feed = FeedService(db).longform();
    expect(feed.needsUpload, isFalse);
    expect(feed.coverageGaps.map((g) => g.concept), containsAll(names));
    expect(r.gapConceptIds.first, id('Integration by Parts'));
  });

  test('re-uploading the same file does not reprocess; after archive it reactivates', () async {
    final first = await svc().upload(pdf.path);
    final calls = model.calls;
    final again = await svc().upload(pdf.path);
    expect(again.alreadyUploaded, isTrue);
    expect(again.materialId, first.materialId);
    expect(model.calls, calls);

    svc().archive(first.materialId);
    expect(FeedService(db).longform().needsUpload, isTrue);
    final back = await svc().upload(pdf.path);
    expect(back.reactivated, isTrue);
    expect(FeedService(db).longform().needsUpload, isFalse);
  });

  test('archive → feed reverts; delete is soft and hidden; reactivate restores', () async {
    final r = await svc().upload(pdf.path);
    final v = addVideo(db, 'ibp-long');
    tag(db, v, id('Integration by Parts'));
    expect(FeedService(db).longform().items.map((c) => c.videoId), [v]);

    svc().archive(r.materialId);
    expect(FeedService(db).longform().needsUpload, isTrue);
    expect(svc().list().single.status, 'archived');

    svc().reactivate(r.materialId);
    expect(FeedService(db).longform().items.map((c) => c.videoId), [v]);

    svc().delete(r.materialId);
    expect(svc().list(), isEmpty);
    expect(db.select('SELECT status FROM materials').single['status'], 'deleted'); // never DELETEd
    expect(FeedService(db).longform().needsUpload, isTrue);
  });

  test('exam date boosts priority; past exams auto-archive', () async {
    final r = await svc().upload(pdf.path, now: DateTime.utc(2026, 11, 22));
    double prio() => db.select('SELECT priority FROM user_active_concepts WHERE concept_id = ?',
        [id('Integration by Parts')]).first['priority'] as double;
    final base = prio();
    svc().setExamDate(r.materialId, DateTime.now().add(const Duration(days: 5)));
    expect(prio(), closeTo(base * 1.8, 1e-9));
    expect(svc().studyingNow().daysToNearestExam, inInclusiveRange(4, 5));

    expect(svc().autoArchivePastExams(now: DateTime.now().add(const Duration(days: 10))), 1);
    expect(svc().list().single.status, 'archived');
    expect(FeedService(db).longform().needsUpload, isTrue);
  });

  test('no text layer → rejected, nothing saved', () async {
    await expectLater(svc(pages: ['  ', 'x']).upload(pdf.path), throwsA(isA<NoTextLayer>()));
    expect(db.select('SELECT * FROM materials'), isEmpty);
  });

  test('model failures still keep rule-based concepts; model optional', () async {
    model.failAll = true;
    final r = await svc().upload(pdf.path);
    expect(r.chunkErrors, greaterThan(0));
    expect(svc().conceptsOf(r.materialId).map((c) => c.name), containsAll(['Integration by Parts', 'Partial Fractions']));

    final pdf2 = File('${pdf.parent.path}/b.pdf')..writeAsStringSync('other bytes');
    final r2 = await MaterialService(db, pdf: FakePdf(sampleChapterPages)).upload(pdf2.path);
    // Rules only: the section headings (7.1, 7.2, 7.3) and labelled blocks map to 3 concepts.
    expect(MaterialService(db, pdf: FakePdf(sampleChapterPages)).conceptsOf(r2.materialId).map((c) => c.name),
        containsAll(['Integration by Parts', 'Partial Fractions', 'Trigonometric Substitution']));
    expect(r2.aiUsed, isFalse);
  });

  test('studying-now summary', () async {
    await svc().upload(pdf.path);
    final s = svc().studyingNow();
    expect(s.materials, 1);
    expect(s.concepts, 4);
    expect(s.daysToNearestExam, isNull);
  });
}
