/// Regression test for "only a handful of concepts from long notes": concepts live
/// inside the sections (box titles, "Term — depends on …" bullets, defining
/// sentences, vocabulary lists), not only in the table of contents.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/graph_seed.dart';
import 'package:theoremfeed/services/llm.dart';
import 'package:theoremfeed/services/material/concept_verifier.dart';
import 'package:theoremfeed/services/material/material_service.dart';
import 'package:theoremfeed/services/material/pdf_text.dart';
import 'package:theoremfeed/services/material/rules_extractor.dart';
import 'package:theoremfeed/services/material/text_pipeline.dart';

import 'support/study_notes_pages.dart';

class _Pdf implements PdfTextSource {
  @override
  Future<List<String>> pages(String filePath) async => studyNotesPages;
}

/// Keeps real concepts among the doubtful finds; records what it was shown.
class _Checker implements JsonModel {
  final seen = <String>[];
  @override
  Future<Map<String, dynamic>> generateJson({required String system, required List<LlmContent> content,
      required Map<String, Object?> schema, String effort = 'low', int maxTokens = 4096}) async {
    final taught = <String>[];
    for (final m in RegExp(r'^(\d+)\. (.*)$', multiLine: true).allMatches((content.single as TextContent).text)) {
      seen.add(m.group(2)!);
      taught.add(m.group(1)!);
    }
    return {'taught': taught, 'mentioned': <String>[]};
  }
}

void main() {
  late AppDatabase db;
  late File pdf;
  setUp(() {
    db = AppDatabase.inMemory();
    loadGraphSeed(db, File(graphSeedAsset).readAsStringSync());
    pdf = File('${Directory.systemTemp.createTempSync('tf').path}/Light notes.pdf')..writeAsStringSync('x');
  });

  test('headings: contents page skipped, plain-numbered chapters found', () {
    final paras = paragraphsFromPages(studyNotesPages);
    final headings = [for (final p in paras) if (p.isHeading) p.text];
    expect(headings, containsAll(['1 What is light?', '2 Reflection — mirrors and images', '3 Describing a lens: the numbers',
      '4.1 It bends towards the normal', '5 Question bank: 20 questions with answers']));
    expect(paras.where((p) => p.page == 1), isEmpty); // the contents page
    expect(paras.where((p) => p.isTitle).map((p) => p.text), containsAll(['Snell’s law', 'Refractive index', 'Power P']));
  });

  test('names from headings and box titles', () {
    expect(conceptNameFromTitle('What is light?'), 'Light');
    expect(conceptNameFromTitle('Reflection — mirrors and images'), 'Reflection');
    expect(conceptNameFromTitle('Faster than light: Cherenkov radiation'), 'Cherenkov radiation');
    expect(conceptNameFromTitle('Pipe closed at one end (flute, clarinet)'), 'Pipe closed at one end');
    expect(conceptNameFromTitle('Uses of total internal reflection'), 'Total internal reflection');
    expect(conceptNameFromTitle('Two kinds of spherical mirror'), 'Spherical mirror');
    expect(conceptNameFromTitle('The lens formula — the one to learn by heart'), 'Lens formula');
    expect(conceptNameFromTitle('What a converging (convex) lens does'), 'Converging lens');
    expect(conceptNameFromTitle('Radius of curvature R'), 'Radius of curvature');
    // Sentence-like headings name nothing.
    for (final h in ['It bends towards the normal', 'Light needs no medium', 'Describing a lens: the numbers',
      'Two rays that meet but never cross', 'What decides the colour of the sky?',
      'The mirror does not move — the image does']) {
      expect(conceptNameFromTitle(h), isNull, reason: h);
    }
  });

  test('rules read the body: box titles, bullets, definitions, vocabulary — fast, no AI', () async {
    final svc = MaterialService(db, pdf: _Pdf()); // no model
    final r = await svc.upload(pdf.path);
    final names = {for (final c in svc.conceptsOf(r.materialId)) c.name};

    expect(names, containsAll([
      'Light', // "1 What is light?" + "Definition  Light is …"
      'Reflection', 'Refraction', 'Dispersion', // chapter headings; "Refraction and dispersion" is two concepts
      'Rectilinear Propagation', // "This property is called rectilinear propagation."
      'Angle of incidence', 'Plane mirror', 'Refractive index', // box titles
      "Snell's Law", // box title mapped onto the knowledge graph
      'Focal length', 'Radius of curvature', 'Magnification', 'Power of a lens', // vocabulary list + definitions
      'Brightness', 'Colour', // "• Brightness — depends on …"
    ]));
    // Not concepts: sentence-like headings, box labels, worked examples, the graph
    // term a definition mentions, and anything from the question bank.
    for (final junk in ['It bends towards the normal', 'Light needs no medium', 'Exam trap', 'Definition',
      'Distance of an image', 'Lens vocabulary', 'Electromagnetic Wave', 'Lateral inversion', 'Diffraction of Light',
      'Atmospheric Refraction', 'Mirage', 'Power (Physics)']) {
      expect(names, isNot(contains(junk)), reason: junk);
    }
    expect(r.conceptCount, greaterThanOrEqualTo(16));
    expect(r.aiUsed, isFalse);
    expect(r.elapsed, lessThan(const Duration(seconds: 2)));

    // Statements come from the notes, without the box label.
    final light = svc.conceptsOf(r.materialId).firstWhere((c) => c.name == 'Light');
    expect(light.statement, startsWith('Light is a form of energy'));
    // Physics notes make physics concepts.
    expect(db.select("SELECT subject FROM concepts WHERE canonical_name = 'Plane mirror'").single['subject'], 'physics');
  });

  test('only the doubtful finds go to the AI; confident ones never do', () async {
    final model = _Checker();
    final svc = MaterialService(db, pdf: _Pdf(), model: model);
    final r = await svc.upload(pdf.path);
    final names = {for (final c in svc.conceptsOf(r.materialId)) c.name};

    expect(model.seen, containsAll(['Total internal reflection', 'Diffuse reflection'])); // "(total internal reflection)."
    expect(model.seen, isNot(contains('Plane mirror')));
    expect(model.seen, isNot(contains('Light')));
    expect(names, contains('Total Internal Reflection'));
    expect(r.candidatesChecked, model.seen.length);
    expect(r.candidatesChecked, lessThanOrEqualTo(MaterialService.maxAiCandidates));
    expect(model.seen.length, lessThan(verifyBatchSize)); // one short call for these notes
  });
}
