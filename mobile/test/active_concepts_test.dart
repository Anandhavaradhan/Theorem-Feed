import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';
import 'package:theoremfeed/services/active_concepts.dart';

import 'support/factories.dart';

final now = DateTime.utc(2026, 11, 21);

void main() {
  test('recency factor', () {
    for (final (days, expected) in [(0, 1.0), (30, 1.0), (105, 0.75), (180, 0.5), (400, 0.5)]) {
      expect(recencyFactor(now.subtract(Duration(days: days)), now), closeTo(expected, 1e-9));
    }
  });

  test('priority sums materials, boosts near exams, ignores archived', () {
    final db = AppDatabase.inMemory();
    final a = addConcept(db, 'A'), b = addConcept(db, 'B');
    final fresh = addMaterial(db, created: now, exam: '2026-11-28');
    final old = addMaterial(db, created: now.subtract(const Duration(days: 105)));
    final archived = addMaterial(db, status: 'archived', created: now);
    addMaterialConcept(db, fresh, a, importance: 0.5, statement: 'fresh A', difficulty: 'highschool');
    addMaterialConcept(db, old, a, importance: 0.8, statement: 'old A', difficulty: 'advanced');
    addMaterialConcept(db, old, b, importance: 0.4);
    addMaterialConcept(db, archived, b, importance: 1.0);

    expect(recomputeUserActiveConcepts(db, now: now), 2);
    final rows = {
      for (final r in db.select(
          'SELECT c.canonical_name, u.* FROM user_active_concepts u JOIN concepts c ON c.id = u.concept_id'))
        r['canonical_name']: r
    };
    expect(rows['A']!['priority'], closeTo((0.5 + 0.8 * 0.75) * 1.8, 1e-9));
    expect(rows['A']!['best_statement'], 'old A');
    expect(rows['A']!['best_difficulty'], 'advanced');
    expect(rows['B']!['priority'], closeTo(0.4 * 0.75, 1e-9));
    expect(parseJsonList(rows['B']!['source_material_ids'] as String), [old]);
  });

  test('past exam does not boost; duplicate rows in one material count once', () {
    final db = AppDatabase.inMemory();
    final a = addConcept(db, 'A');
    final m = addMaterial(db, created: now, exam: '2026-11-20');
    addMaterialConcept(db, m, a, importance: 0.5);
    addMaterialConcept(db, m, a, importance: 0.3);
    recomputeUserActiveConcepts(db, now: now);
    expect(db.select('SELECT priority FROM user_active_concepts').first['priority'], closeTo(0.5, 1e-9));
  });
}
