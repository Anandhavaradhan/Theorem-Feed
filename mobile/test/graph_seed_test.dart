import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/concept_matcher.dart';
import 'package:theoremfeed/services/feed_service.dart';
import 'package:theoremfeed/services/graph_seed.dart';
import 'support/seed_phase_a.dart';

void main() {
  final json = File(graphSeedAsset).readAsStringSync();

  test('seed file meets the spec: 300–500 concepts, 50–100 math pool theorems with LaTeX', () {
    final concepts = ((jsonDecode(json) as Map)['concepts'] as List).cast<Map<String, dynamic>>();
    expect(concepts.length, inInclusiveRange(300, 500));
    final pool = concepts.where((c) => c['in_theorem_pool'] == true).toList();
    expect(pool.length, inInclusiveRange(50, 100));
    expect(pool.every((c) => c['subject'] == 'math' && (c['latex'] as String).isNotEmpty), isTrue);
    expect({for (final c in concepts) c['subject']}, {'math', 'physics', 'cs'});
  });

  test('loads once, merges with Phase A concepts, builds prerequisite edges', () {
    final db = AppDatabase.inMemory();
    seedPhaseA(db); // creates 5 concepts first, as on an existing install
    final r = loadGraphSeed(db, json)!;
    expect(r.updated, 5);
    expect(r.inserted + r.updated, greaterThanOrEqualTo(300));
    expect(loadGraphSeed(db, json), isNull); // idempotent

    final count = db.select('SELECT count(*) AS n FROM concepts').first['n'];
    expect(count, r.inserted + r.updated);

    // "Integration by Parts requires Product Rule"
    final prereqs = db.select('''
      SELECT p.canonical_name FROM concept_edges e
      JOIN concepts c ON c.id = e.from_concept JOIN concepts p ON p.id = e.to_concept
      WHERE c.canonical_name = 'Integration by Parts' AND e.relation = 'requires' ORDER BY 1''').map((x) => x['canonical_name']);
    expect(prereqs, ['Fundamental Theorem of Calculus', 'Product Rule']);

    // Phase A concept enriched, not duplicated; pool order + LaTeX present.
    final taylor = db.select("SELECT * FROM concepts WHERE canonical_name = 'Taylor Series'");
    expect(taylor, hasLength(1));
    expect(taylor.first['in_theorem_pool'], 1);
    expect(taylor.first['latex'], isNotNull);
    expect(parseJsonList(taylor.first['aliases'] as String), contains('Maclaurin series'));

    // The matcher works against the full graph.
    final m = ConceptMatcher(db);
    expect(m.match('pythagoras theorem')?.name, 'Pythagorean Theorem');
    expect(m.match('L\'Hopital rule')?.name, "L'Hôpital's Rule");
    expect(m.match('FTC')?.name, 'Fundamental Theorem of Calculus');
    expect(m.match('Fourier transform')?.name, 'Fourier Transform');
    expect(m.match('Fourier series')?.name, 'Fourier Series');
    expect(m.match('dijkstra shortest path')?.name, "Dijkstra's Algorithm");

    // Seeding the graph never puts anything in the feeds by itself.
    expect(FeedService(db).shorts().items, isEmpty);
  });
}
