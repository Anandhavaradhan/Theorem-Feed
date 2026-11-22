import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/concept_service.dart';
import 'package:theoremfeed/services/graph_seed.dart';

import 'support/factories.dart';

String id(AppDatabase db, String name) =>
    db.select('SELECT id FROM concepts WHERE canonical_name = ?', [name]).first['id'] as String;

void main() {
  late AppDatabase db;
  late ConceptService svc;
  setUp(() {
    db = AppDatabase.inMemory();
    loadGraphSeed(db, File(graphSeedAsset).readAsStringSync());
    svc = ConceptService(db);
  });

  test('prerequisite chain is breadth-first, nearest first, each once', () {
    final chain = svc.prerequisiteChain(id(db, 'Integration by Parts'));
    expect(chain.where((p) => p.depth == 1).map((p) => p.name), ['Fundamental Theorem of Calculus', 'Product Rule']);
    expect(chain.map((p) => p.name).toSet().length, chain.length);
    expect(chain.map((p) => p.name), contains('Derivative'));
    expect(chain.every((p) => p.depth <= 3), isTrue);
  });

  test('pool theorem outside material: graph statement + LaTeX, only pool shorts, can find videos', () {
    final pyth = id(db, 'Pythagorean Theorem');
    final poolShort = addVideo(db, 'ps', short: true, pool: true);
    final longV = addVideo(db, 'lv');
    tag(db, poolShort, pyth);
    tag(db, longV, pyth);
    final d = svc.detail(pyth)!;
    expect(d.inTheoremPool, isTrue);
    expect(d.inMaterial, isFalse);
    expect(d.latex, 'a^2 + b^2 = c^2');
    expect(d.videos.map((v) => v.videoId), [poolShort]); // long-form needs the concept in material
    expect(d.videos.single.reasonLabel, 'Math theorem: Pythagorean Theorem');
    expect(d.canFindVideos, isTrue);
  });

  test('material concept: material statement/LaTeX/chapter, long-form shown, Go deeper available', () {
    final ibp = id(db, 'Integration by Parts');
    final m = addMaterial(db);
    db.execute('''INSERT INTO material_concepts (id, material_id, concept_id, statement, latex, chapter, difficulty, importance)
                  VALUES ('mc1', ?, ?, 'Our book: ∫u dv = uv − ∫v du', 'uv - \\int v\\,du', '7.2', 'undergrad', 0.9)''', [m, ibp]);
    recomputeUserActiveConcepts(db);
    final longV = addVideo(db, 'lv');
    tag(db, longV, ibp);
    final d = svc.detail(ibp)!;
    expect(d.inMaterial, isTrue);
    expect(d.statement, 'Our book: ∫u dv = uv − ∫v du');
    expect(d.chapter, '7.2');
    expect(d.videos.single.reasonLabel, 'From your material: Integration by Parts');
    expect(svc.goDeeper(ibp)?.videoId, longV);
  });

  test('out-of-scope concept: no videos listed, cannot ingest, no Go deeper', () {
    final laplace = id(db, 'Laplace Transform');
    final v = addVideo(db, 'stale'); // e.g. left over from archived material
    tag(db, v, laplace);
    final d = svc.detail(laplace)!;
    expect(d.videos, isEmpty);
    expect(d.canFindVideos, isFalse);
    expect(svc.goDeeper(laplace), isNull);
  });

  test('save toggles a soft flag on watch history', () {
    final v = addVideo(db, 'x', short: true, pool: true);
    expect(svc.isSaved(v), isFalse);
    expect(svc.toggleSaved(v), isTrue);
    expect(svc.isSaved(v), isTrue);
    expect(svc.toggleSaved(v), isFalse);
    expect(db.select('SELECT count(*) AS n FROM watch_history').first['n'], 1); // never deleted
  });

  test('library stats', () {
    final s = svc.libraryStats();
    expect(s['pool_theorems'], inInclusiveRange(50, 100));
    expect(s['pool_shorts'], 0);
  });
}
