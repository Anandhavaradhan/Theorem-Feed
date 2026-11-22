/// Phase A walking-skeleton seed: 5 hardcoded videos, written on first launch.
///
/// To stay honest to the scope rules, the videos are not injected into the
/// feed directly: a clearly-labelled sample material makes their concepts
/// user-active through the real recompute, and the long-form feed shows them
/// via its normal predicate. Archive that material (Phase C) and Home reverts
/// to the upload prompt. Idempotent.
library;

import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import 'active_concepts.dart';

const sampleMaterialTitle = 'Phase A sample material (dev seed)';
const sampleMaterialHash = 'phase-a-seed-v1';

const _seed = <Map<String, Object?>>[
  {
    'youtube_id': 'WUvTyaaNkzM', 'title': 'The essence of calculus', 'duration_sec': 1020,
    'name': 'Definite Integral', 'aliases': ['integral', 'area under a curve'], 'type': 'definition',
    'statement': 'The definite integral ∫_a^b f(x) dx is the limit of Riemann sums: the signed area between f and the x-axis on [a, b].',
    'latex': r'\int_a^b f(x)\,dx = \lim_{n\to\infty}\sum_{i=1}^{n} f(x_i^*)\,\Delta x',
    'chapter': '1', 'difficulty': 'highschool', 'importance': 0.9,
  },
  {
    'youtube_id': 'r6sGWTCMz2k', 'title': 'But what is a Fourier series? From heat flow to drawing with circles',
    'duration_sec': 1500, 'name': 'Fourier Series', 'aliases': ['fourier expansion'], 'type': 'theorem',
    'statement': 'A periodic function can be written as a sum of complex exponentials c_n e^{2πinx}, with c_n = ∫_0^1 f(x) e^{-2πinx} dx.',
    'latex': r'f(x) = \sum_{n=-\infty}^{\infty} c_n e^{2\pi i n x}',
    'chapter': '4', 'difficulty': 'undergrad', 'importance': 0.8,
  },
  {
    'youtube_id': 'fNk_zzaMoSs', 'title': 'Vectors | Chapter 1, Essence of linear algebra', 'duration_sec': 600,
    'name': 'Vector', 'aliases': ['vectors'], 'type': 'definition',
    'statement': 'A vector is an element of a vector space; in R^n it is an ordered list of n numbers, added componentwise and scaled by real numbers.',
    'latex': null, 'chapter': '2', 'difficulty': 'highschool', 'importance': 0.7,
  },
  {
    'youtube_id': 'HZGCoVF3YvM', 'title': 'Bayes theorem, the geometry of changing beliefs', 'duration_sec': 900,
    'name': "Bayes' Theorem", 'aliases': ['bayes rule', 'bayes theorem'], 'type': 'theorem',
    'statement': 'P(H|E) = P(E|H)·P(H) / P(E): the posterior probability of a hypothesis given evidence.',
    'latex': r'P(H\mid E) = \frac{P(E\mid H)\,P(H)}{P(E)}',
    'chapter': '3', 'difficulty': 'undergrad', 'importance': 0.85,
  },
  {
    'youtube_id': '3d6DsjIBzJ4', 'title': 'Taylor series | Chapter 11, Essence of calculus', 'duration_sec': 1320,
    'name': 'Taylor Series', 'aliases': ['taylor expansion', 'taylor polynomial'], 'type': 'theorem',
    'statement': 'A smooth f near a equals Σ f^(n)(a)(x−a)^n / n!, approximating f by polynomials matching its derivatives at a.',
    'latex': r'f(x) = \sum_{n=0}^{\infty} \frac{f^{(n)}(a)}{n!}(x-a)^n',
    'chapter': '1', 'difficulty': 'undergrad', 'importance': 0.9,
  },
];

/// Returns true if anything was written.
bool seedPhaseA(AppDatabase db) {
  if (db.select('SELECT 1 FROM materials WHERE file_hash = ?', [sampleMaterialHash]).isNotEmpty) return false;
  const uuid = Uuid();
  final now = nowMs();
  db.transaction(() {
    final materialId = uuid.v4();
    db.execute(
      "INSERT INTO materials (id, title, file_hash, page_count, status, created_at) VALUES (?, ?, ?, 0, 'active', ?)",
      [materialId, sampleMaterialTitle, sampleMaterialHash, now],
    );
    for (final s in _seed) {
      final existing = db.select('SELECT id FROM concepts WHERE canonical_name = ?', [s['name']]);
      final conceptId = existing.isNotEmpty ? existing.first['id'] as String : uuid.v4();
      if (existing.isEmpty) {
        db.execute(
          "INSERT INTO concepts (id, canonical_name, aliases, type, subject, description) VALUES (?, ?, ?, ?, 'math', ?)",
          [conceptId, s['name'], jsonList(s['aliases']! as List), s['type'], s['statement']],
        );
      }
      db.execute(
        'INSERT INTO material_concepts (id, material_id, concept_id, statement, latex, chapter, difficulty, importance) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [uuid.v4(), materialId, conceptId, s['statement'], s['latex'], s['chapter'], s['difficulty'], s['importance']],
      );
      final yt = s['youtube_id']! as String;
      if (db.select('SELECT 1 FROM videos WHERE source_id = ?', [yt]).isEmpty) {
        final videoId = uuid.v4();
        db.execute(
          'INSERT INTO videos (id, source, source_id, title, duration_sec, thumbnail_url, is_short, is_theorem, '
          "subject, in_theorem_pool, status, created_at) VALUES (?, 'youtube', ?, ?, ?, ?, 0, ?, 'math', 0, 'active', ?)",
          [videoId, yt, s['title'], s['duration_sec'], 'https://i.ytimg.com/vi/$yt/hqdefault.jpg',
           boolInt(s['type'] == 'theorem'), now],
        );
        db.execute(
          'INSERT INTO video_concepts (video_id, concept_id, confidence, is_primary) VALUES (?, ?, 1.0, 1)',
          [videoId, conceptId],
        );
      }
    }
  });
  recomputeUserActiveConcepts(db);
  return true;
}
