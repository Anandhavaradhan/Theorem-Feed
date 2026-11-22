/// Regression test for "it always finds zero concepts": the text of a real PDF
/// (one line per visual line, no blank lines between paragraphs) must yield the
/// chapter's concepts with the fast rules alone, no AI.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/graph_seed.dart';
import 'package:theoremfeed/services/material/material_service.dart';
import 'package:theoremfeed/services/material/pdf_text.dart';
import 'package:theoremfeed/services/material/text_pipeline.dart';

import 'support/real_pdf_pages.dart';

class _Pdf implements PdfTextSource {
  @override
  Future<List<String>> pages(String filePath) async => realPdfPages;
}

void main() {
  test('paragraphs are rebuilt from PDF lines: headings and labelled blocks stand alone', () {
    final paras = paragraphsFromPages(realPdfPages);
    final headings = [for (final p in paras) if (p.isHeading) p.text];
    expect(headings, containsAll(['7.1 Integration by Parts', '7.4 Partial Fractions', '7.8 Improper Integrals']));
    expect(paras.any((p) => p.text.startsWith('Theorem 7.1.')), isTrue);
    expect(paras.any((p) => p.text.startsWith('Definition 7.4.')), isTrue);
    // Header and page numbers removed; lines of one paragraph joined.
    expect(paras.any((p) => p.text.contains('MATH 201')), isFalse);
    final thm = paras.firstWhere((p) => p.text.startsWith('Theorem 7.1.'));
    expect(thm.text, contains('the integral of u dv equals uv minus the integral of v du'));
    expect(thm.heading.section, '7.1 Integration by Parts');
  });

  test('rules alone find the chapter\'s concepts, fast', () async {
    final db = AppDatabase.inMemory();
    loadGraphSeed(db, File(graphSeedAsset).readAsStringSync());
    final f = File('${Directory.systemTemp.createTempSync('tf').path}/Calc Ch7.pdf')..writeAsStringSync('x');
    final svc = MaterialService(db, pdf: _Pdf()); // no model: rules only
    final r = await svc.upload(f.path);

    final names = {for (final c in svc.conceptsOf(r.materialId)) c.name};
    expect(names, containsAll([
      'Integration by Parts', // section heading + Theorem 7.1 + "is called integration by parts"
      'Trigonometric Integrals', // section heading (new concept, not in the graph)
      'Trigonometric Substitution', // heading + "This method is called trigonometric substitution."
      'Partial Fractions', // heading, mapped onto the graph
      'Improper Integral', // "7.8 Improper Integrals" mapped onto the graph's singular name
    ]));
    expect(names, isNot(contains('Exercises')));
    expect(names, isNot(contains('Function'))); // generic word, not the topic
    expect(r.conceptCount, greaterThanOrEqualTo(5));
    expect(r.aiUsed, isFalse);
    expect(r.elapsed, lessThan(const Duration(seconds: 2)));

    // Statements come from the PDF, and passing mentions are recorded as prerequisites.
    final ibp = svc.conceptsOf(r.materialId).firstWhere((c) => c.name == 'Integration by Parts');
    expect(ibp.statement, contains('integral of u dv equals uv minus the integral of v du'));
    expect(ibp.section, '7.1 Integration by Parts');
    final prereqs = db.select('''
      SELECT p.canonical_name FROM material_concepts mc JOIN concepts c ON c.id = mc.concept_id,
           json_each(mc.prerequisites_mentioned) j JOIN concepts p ON p.id = j.value
      WHERE c.canonical_name = 'Integration by Parts' ''').map((x) => x['canonical_name']).toSet();
    expect(prereqs, contains('Product Rule'));
  });
}
