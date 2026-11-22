/// §15.4 Feed scope test (critical). Any violation = bug.
///   Every long-form card: primary_concept ∈ user_active_concepts.
///   Every short: in theorem pool (math) OR primary_concept ∈ user_active_concepts.
///   Every card: non-empty reason label.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/active_concepts.dart';
import 'package:theoremfeed/services/feed_service.dart';

import 'support/factories.dart';

void _randomWorld(AppDatabase db, int seed) {
  final rng = Random(seed);
  T pick<T>(List<T> xs) => xs[rng.nextInt(xs.length)];
  final concepts = [for (var i = 0; i < 12; i++) addConcept(db, 'C$seed-$i', pool: rng.nextDouble() < 0.3)];
  for (var i = 0; i < 3; i++) {
    final m = addMaterial(db, status: pick(['active', 'active', 'archived', 'deleted']));
    for (final c in ([...concepts]..shuffle(rng)).take(4)) {
      addMaterialConcept(db, m, c, importance: 0.1 + rng.nextDouble() * 0.9);
    }
  }
  for (var i = 0; i < 40; i++) {
    final short = rng.nextDouble() < 0.5;
    final v = addVideo(db, 'v$seed-$i',
        short: short,
        pool: short && rng.nextDouble() < 0.4,
        status: pick(['active', 'active', 'active', 'active', 'rejected_lang', 'rejected_edu']),
        subject: pick(['math', 'math', 'physics']));
    final tags = ([...concepts]..shuffle(rng)).take(1 + rng.nextInt(2)).toList();
    for (var j = 0; j < tags.length; j++) {
      tag(db, v, tags[j], primary: j == 0 || rng.nextDouble() < 0.3);
    }
  }
  recomputeUserActiveConcepts(db);
}

Set<String> _primaries(AppDatabase db, String videoId) => {
      for (final r in db.select('SELECT concept_id FROM video_concepts WHERE video_id = ? AND is_primary = 1', [videoId]))
        r['concept_id'] as String
    };

void main() {
  for (var seed = 0; seed < 25; seed++) {
    test('feed scope property (seed $seed)', () {
      final db = AppDatabase.inMemory();
      _randomWorld(db, seed);
      final feed = FeedService(db);
      final active = {for (final r in db.select('SELECT concept_id FROM user_active_concepts')) r['concept_id']};

      final longform = feed.longform(limit: 100);
      for (final c in longform.items) {
        final v = db.select('SELECT * FROM videos WHERE id = ?', [c.videoId]).first;
        expect(v['status'], 'active');
        expect(v['is_short'], 0);
        expect(active, contains(c.conceptId));
        expect(_primaries(db, c.videoId), contains(c.conceptId));
        expect(c.reasonLabel, 'From your material: ${c.conceptName}');
      }

      for (final c in feed.shorts(limit: 100).items) {
        final v = db.select('SELECT * FROM videos WHERE id = ?', [c.videoId]).first;
        expect(v['status'], 'active');
        expect(v['is_short'], 1);
        final inPool = v['in_theorem_pool'] == 1 && v['subject'] == 'math';
        expect(inPool || _primaries(db, c.videoId).intersection(active).isNotEmpty, isTrue);
        expect(c.reasonLabel, matches(RegExp(r'^(From your material|Math theorem): .+')));
        if (c.fromMaterial) expect(active, contains(c.conceptId));
      }

      final gapIds = {for (final g in longform.coverageGaps) g.conceptId};
      expect(active.containsAll(gapIds), isTrue);
      expect(gapIds.intersection({for (final c in longform.items) c.conceptId}), isEmpty);
    });
  }

  test('no material: upload state for long-form, theorem pool for shorts', () {
    final db = AppDatabase.inMemory();
    final c = addConcept(db, 'Pythagorean Theorem', pool: true, poolOrder: 1);
    final s = addVideo(db, 'pool1', short: true, pool: true);
    final l = addVideo(db, 'long1');
    tag(db, s, c);
    tag(db, l, c);
    final feed = FeedService(db);
    final lf = feed.longform();
    expect(lf.items, isEmpty);
    expect(lf.needsUpload, isTrue); // never a fallback feed
    final sh = feed.shorts();
    expect(sh.items.map((x) => x.videoId), [s]);
    expect(sh.items.single.reasonLabel, 'Math theorem: Pythagorean Theorem');
  });

  test('theorem pool follows curated order on cold start', () {
    final db = AppDatabase.inMemory();
    final second = addConcept(db, 'Taylor', pool: true, poolOrder: 2);
    final first = addConcept(db, 'Pythagoras', pool: true, poolOrder: 1);
    final v2 = addVideo(db, 's2', short: true, pool: true, createdAt: 1);
    final v1 = addVideo(db, 's1', short: true, pool: true, createdAt: 2);
    tag(db, v2, second);
    tag(db, v1, first);
    expect(FeedService(db).shorts().items.map((x) => x.videoId), [v1, v2]);
  });

  test('archiving material reverts long-form; gaps shown for uncovered concepts', () {
    final db = AppDatabase.inMemory();
    final a = addConcept(db, 'A'), b = addConcept(db, 'B');
    final m = addMaterial(db);
    final va = addVideo(db, 'va');
    addMaterialConcept(db, m, a, importance: 0.9);
    addMaterialConcept(db, m, b, importance: 0.5);
    tag(db, va, a);
    recomputeUserActiveConcepts(db);
    final feed = FeedService(db);
    var lf = feed.longform();
    expect(lf.items.map((x) => x.videoId), [va]);
    expect(lf.coverageGaps.map((g) => g.concept), ['B']);

    db.execute("UPDATE materials SET status = 'archived' WHERE id = ?", [m]);
    recomputeUserActiveConcepts(db);
    lf = feed.longform();
    expect(lf.items, isEmpty);
    expect(lf.needsUpload, isTrue);
  });

  test('long-form caps 3 videos per concept in the visible window', () {
    final db = AppDatabase.inMemory();
    final a = addConcept(db, 'A'), b = addConcept(db, 'B');
    final m = addMaterial(db);
    addMaterialConcept(db, m, a, importance: 1.0);
    addMaterialConcept(db, m, b, importance: 0.2);
    for (var i = 0; i < 5; i++) {
      tag(db, addVideo(db, 'a$i'), a);
    }
    tag(db, addVideo(db, 'b0'), b);
    recomputeUserActiveConcepts(db);
    final names = FeedService(db).longform(limit: 4).items.map((x) => x.conceptName).toList();
    expect(names.where((n) => n == 'A').length, 3);
    expect(names, contains('B'));
  });

  test('interleave keeps ~65% material and avoids back-to-back concepts', () {
    final cs = ['c0', 'c1', 'c2', 'c3'];
    List<FeedRow> rows(int n, bool mat) => [
          for (var i = 0; i < n; i++)
            FeedRow(videoId: '$mat$i', title: '', thumbnailUrl: null, durationSec: null, isShort: true,
                conceptId: cs[i % 4], conceptName: '', priority: 0, finalScore: null, fromMaterial: mat),
        ];
    final out = interleave(rows(40, true), rows(40, false), 0.65);
    final mat = out.take(20).where((r) => r.fromMaterial).length;
    expect(mat, inInclusiveRange(12, 14));
    for (var i = 1; i < 40; i++) {
      expect(out[i].conceptId, isNot(out[i - 1].conceptId));
    }
  });

  test('Shorts mix: every concept early, never one concept in a run; same seed, same order', () {
    final rows = [
      for (final c in ['a', 'b', 'c', 'd'])
        for (var i = 0; i < 5; i++)
          FeedRow(videoId: '$c$i', title: '', thumbnailUrl: null, durationSec: 30, isShort: true, conceptId: c,
              conceptName: c, priority: c == 'a' ? 9 : 1, finalScore: null, fromMaterial: true),
    ];
    final mixed = mixAcrossConcepts(rows, Random(7));
    expect(mixed.take(4).map((r) => r.conceptId).toSet(), {'a', 'b', 'c', 'd'}); // not all of 'a' first
    for (var i = 1; i < mixed.length; i++) {
      expect(mixed[i].conceptId == mixed[i - 1].conceptId, isFalse);
    }
    expect(mixAcrossConcepts(rows, Random(7)).map((r) => r.videoId), mixed.map((r) => r.videoId));
  });
}
