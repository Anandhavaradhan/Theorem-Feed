/// §11.8 search golden set: 20 queries covering exact concept, typo, natural
/// language, formula, theorem pool, out-of-scope and multi-concept. Each must
/// put its expected concept in the top 3 groups (or return the right card type).
/// Run on every search change.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/graph_seed.dart';
import 'package:theoremfeed/services/search/search_service.dart';

import 'support/factories.dart';

late AppDatabase db;

String cid(String name) =>
    db.select('SELECT id FROM concepts WHERE canonical_name = ?', [name]).first['id'] as String;

void video(String src, String title, String concept, {String transcript = '', bool short = false, bool pool = false}) {
  final v = addVideo(db, src, short: short, pool: pool);
  db.execute('UPDATE videos SET title = ?, transcript = ? WHERE id = ?', [title, transcript, v]);
  tag(db, v, cid(concept));
}

void buildLibrary() {
  db = AppDatabase.inMemory();
  loadGraphSeed(db, File('assets/graph/graph_seed_v1.json').readAsStringSync());
  final m = addMaterial(db, title: 'Calculus II + Probability');
  for (final (name, statement) in [
    ('Integration by Parts', '∫ u dv = uv − ∫ v du, a technique for integrating products of functions'),
    ('Partial Fractions', 'Splitting a rational function into simple fractions to integrate it'),
    ('Taylor Series', 'A smooth f near a equals Σ f⁽ⁿ⁾(a)(x − a)ⁿ/n!'),
    ('Fourier Series', 'A periodic function as a sum of sines and cosines'),
    ('Geometric Series', 'Σ arᵏ = a/(1 − r) for |r| < 1'),
    ("Bayes' Theorem", 'P(H|E) = P(E|H)P(H)/P(E): the probability of a hypothesis given evidence'),
    ('Chain Rule', "(f ∘ g)'(x) = f'(g(x)) g'(x)"),
    ('Product Rule', "(uv)' = u'v + uv'"), // in material, but no videos → coverage gap
  ]) {
    addMaterialConcept(db, m, cid(name), statement: statement, importance: 0.8);
  }
  recomputeUserActiveConcepts(db);

  video('ibp1', 'Integration by parts explained', 'Integration by Parts',
      transcript: 'we integrate the product of two functions using u dv equals uv minus the integral of v du');
  video('ibp2', 'Calculus 2 lecture 9: IBP examples', 'Integration by Parts',
      transcript: 'more examples of integration by parts with exponentials and logs');
  video('pf1', 'Partial fraction decomposition', 'Partial Fractions',
      transcript: 'split a rational function into simpler fractions before integrating');
  video('ts1', 'Taylor series | Essence of calculus', 'Taylor Series',
      transcript: 'approximating functions with polynomials, the taylor series expansion around a point');
  video('fs1', 'But what is a Fourier series?', 'Fourier Series',
      transcript: 'any periodic function can be written as a sum of sines and cosines, a fourier series');
  video('gs1', 'Geometric series sum formula', 'Geometric Series',
      transcript: 'the sum of a geometric series a over one minus r when r is less than one');
  video('bt1', 'Bayes theorem, the geometry of changing beliefs', "Bayes' Theorem",
      transcript: 'how to update the probability of a hypothesis given new evidence');
  video('cr1', 'The chain rule', 'Chain Rule', transcript: 'differentiate a composition of functions');
  // Theorem-pool shorts.
  video('py1', 'Pythagorean theorem in 60 seconds', 'Pythagorean Theorem',
      transcript: 'a squared plus b squared equals c squared', short: true, pool: true);
  video('eu1', "Euler's identity visualised", "Euler's Identity",
      transcript: 'e to the i pi plus one equals zero', short: true, pool: true);
}

/// (query, expected concept in top-3 groups) — or a card expectation.
final golden = <(String, String?, String)>[
  ('integration by parts', 'Integration by Parts', 'exact concept'),
  ('IBP', 'Integration by Parts', 'alias'),
  ('integraton by part', 'Integration by Parts', 'typo'),
  ('taylor series', 'Taylor Series', 'exact concept'),
  ('taylr seris', 'Taylor Series', 'typo'),
  ('fourier', 'Fourier Series', 'single word'),
  ('how do I integrate a product of two functions', 'Integration by Parts', 'natural language'),
  ('∫ u dv = uv − ∫ v du', 'Integration by Parts', 'formula (unicode)'),
  (r'e^{i\pi} + 1 = 0', "Euler's Identity", 'formula (LaTeX), theorem pool'),
  ('pythagorean theorem', 'Pythagorean Theorem', 'theorem pool'),
  ('pythagoras theorem', 'Pythagorean Theorem', 'theorem pool alias'),
  ('series', 'Taylor Series', 'multi-concept'),
  ('bayes rule', "Bayes' Theorem", 'alias'),
  ('probability of a hypothesis given evidence', "Bayes' Theorem", 'natural language'),
  ('chain rule', 'Chain Rule', 'exact concept'),
  ('partial fraction decomposition', 'Partial Fractions', 'alias'),
  ('sum of a geometric series', 'Geometric Series', 'natural language'),
  ('product rule', 'Product Rule', 'coverage gap'),
  ("dijkstra's algorithm", null, 'out of scope (graph concept, not studied)'),
  ('chocolate cake recipe', null, 'out of scope (nothing)'),
];

void main() {
  setUpAll(buildLibrary);

  test('golden set has 20 queries covering every case', () {
    expect(golden, hasLength(20));
    expect({for (final g in golden) g.$3.split(' ').first},
        containsAll(['exact', 'typo', 'natural', 'formula', 'theorem', 'out', 'multi-concept']));
  });

  for (final (query, expected, kind) in golden) {
    test('[$kind] "$query"', () {
      final r = SearchService(db).search(query);
      final top3 = r.groups.take(3).map((g) => g.conceptName).toList();
      if (expected == null) {
        expect(r.outOfScope, isNotNull, reason: 'got groups $top3');
        expect(r.groups, isEmpty);
        expect(r.outOfScope!.message, contains('Not in your material'));
      } else {
        expect(top3, contains(expected), reason: 'intent=${r.understanding.intent} groups=$top3');
        // Every group carries a reason label.
        expect(r.groups.every((g) => g.reasonLabel.isNotEmpty), isTrue);
      }
    });
  }

  test('concept intent: a tagged video is in the top 3 of its group, and the group comes first', () {
    final r = SearchService(db).search('integration by parts');
    expect(r.understanding.intent, QueryIntent.concept);
    expect(r.groups.first.conceptName, 'Integration by Parts');
    expect(r.groups.first.videos.take(3).map((v) => v.title), contains('Integration by parts explained'));
    expect(r.groups.first.chapter, isNull); // fixture material has no chapters
  });

  test('coverage gap and prerequisite gap cards', () {
    final gap = SearchService(db).search('product rule');
    expect(gap.groups.first.kind, GroupKind.coverageGap);
    // Integration by Parts requires Product Rule (graph), which has no videos → prerequisite gap.
    final ibp = SearchService(db).search('integration by parts');
    expect(ibp.groups.where((g) => g.kind == GroupKind.prerequisiteGap).map((g) => g.conceptName),
        contains('Product Rule'));
  });

  test('theorem-pool fallback and theorem labels', () {
    final r = SearchService(db).search('pythagorean theorem');
    expect(r.groups.first.kind, GroupKind.theorem);
    expect(r.groups.first.reasonLabel, 'Math theorem: Pythagorean Theorem');
    final pool = SearchService(db).search('chocolate cake recipe', theoremOnly: true);
    expect(pool.outOfScope!.alreadyTheoremOnly, isTrue);
  });

  test('no active material: theorem pool only, with the notice', () {
    db.execute("UPDATE materials SET status = 'archived'");
    recomputeUserActiveConcepts(db);
    final svc = SearchService(db);
    final r = svc.search('integration by parts');
    expect(r.materialInactive, isTrue);
    expect(r.outOfScope, isNotNull); // material concepts are not searchable without material
    expect(svc.search('pythagorean theorem').groups.first.conceptName, 'Pythagorean Theorem');
    db.execute("UPDATE materials SET status = 'active'");
    recomputeUserActiveConcepts(db);
  });

  test('scope: archived-material videos never appear; cache invalidates on change', () {
    final svc = SearchService(db);
    expect(svc.search('chain rule').groups.first.conceptName, 'Chain Rule');
    expect(svc.search('chain rule').fromCache, isTrue);
    db.execute("UPDATE materials SET status = 'archived'");
    recomputeUserActiveConcepts(db);
    final r = svc.search('chain rule');
    expect(r.fromCache, isFalse);
    expect(r.groups, isEmpty);
    db.execute("UPDATE materials SET status = 'active'");
    recomputeUserActiveConcepts(db);
  });

  test('performance: under 150 ms per query on this machine (cold, no cache)', () {
    final sw = Stopwatch()..start();
    for (final (q, _, _) in golden) {
      SearchService(db).search('$q ${sw.elapsedMicroseconds}'); // defeat the cache
    }
    final perQuery = sw.elapsedMilliseconds / golden.length;
    expect(perQuery, lessThan(150));
  });
}
