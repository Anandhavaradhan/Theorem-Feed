import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/graph_seed.dart';
import 'package:theoremfeed/services/material/material_service.dart';
import 'package:theoremfeed/services/material/pdf_text.dart';
import 'package:theoremfeed/services/material/rules_extractor.dart';

import 'support/formula_sheet_pages.dart';

class _Pdf implements PdfTextSource {
  @override
  Future<List<String>> pages(String filePath) async => formulaSheetPages;
}

void main() {
  test('formula sheet: topic headings, named formulas and laws; no labels, constants or table cells', () async {
    final db = AppDatabase.inMemory();
    loadGraphSeed(db, File(graphSeedAsset).readAsStringSync());
    final f = File('${Directory.systemTemp.createTempSync('tf').path}/Formula sheet.pdf')..writeAsStringSync('x');
    final svc = MaterialService(db, pdf: _Pdf()); // rules only
    final r = await svc.upload(f.path);
    final concepts = svc.conceptsOf(r.materialId);
    final names = {for (final c in concepts) c.name};

    expect(names, containsAll([
      "Boyle's law", "Charles's law", // "Boyle P1 V1 = …": a scientist's name labels a law
      'Molarity', 'Mole fraction', 'Dilution', 'Neutralisation', // named formula lines
      'Acids', 'Bases', // "Acids, bases, pH": a list heading, one concept each
      'Organic chemistry', // "Organic" on a chemistry sheet
    ]));
    for (final junk in ['Constants', 'Exceptions', 'Argon', 'Metal', 'Series', 'Percentage', 'Mole fraction xA']) {
      expect(names, isNot(contains(junk)), reason: junk);
    }
    // The topic heading is the chapter of the formulas under it.
    expect(concepts.firstWhere((c) => c.name == 'Molarity').chapter, 'Concentration');
    // The sheet's topic is saved for searches ("Molarity chemistry").
    expect(db.select('SELECT topic FROM materials').single['topic'], 'chemistry');
  });

  test('detectTopic', () {
    expect(detectTopic('moles of solute, molarity of the acid, oxidation number of each atom'), 'chemistry');
    expect(detectTopic('the wave travels with speed v; frequency and wavelength of sound'), 'physics');
    expect(detectTopic('cells, tissues and enzymes in plants'), 'biology');
  });

  test('formula line names', () {
    expect(formulaConceptName('Boyle'), "Boyle's law");
    expect(formulaConceptName('de Broglie'), 'de Broglie wavelength');
    expect(formulaConceptName('Avg atomic mass'), 'Average atomic mass');
    expect(formulaConceptName('Sum'), isNull);
    expect(formulaConceptName('Exceptions'), isNull);
  });
}
