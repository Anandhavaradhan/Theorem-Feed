/// Recompute the derived `user_active_concepts` cache (§6.4 step 4).
///
/// priority(c) = Σ_material (importance × recency_factor(material)) × exam_proximity_boost(c)
///
///   recency_factor:       1.0 if material age ≤ 30 days, linear down to 0.5 at 180 days, 0.5 after.
///   exam_proximity_boost: 1.8 if any active material containing c has an exam within 14 days.
///   best_statement / best_difficulty: from the highest-importance material for c.
///
/// Only materials with status='active' count, so archiving or deleting material
/// drops its concepts out of feeds and search on the next recompute.
library;

import '../data/app_database.dart';

const examBoost = 1.8;
const examWindowDays = 14;

double recencyFactor(DateTime createdAt, DateTime now) {
  final ageDays = now.difference(createdAt).inMilliseconds / Duration.millisecondsPerDay;
  if (ageDays <= 30) return 1.0;
  if (ageDays >= 180) return 0.5;
  return 1.0 - 0.5 * (ageDays - 30) / 150;
}

bool examIsNear(String? examDate, DateTime now) {
  if (examDate == null) return false;
  final exam = DateTime.parse(examDate);
  final today = DateTime.utc(now.year, now.month, now.day);
  final days = DateTime.utc(exam.year, exam.month, exam.day).difference(today).inDays;
  return days >= 0 && days <= examWindowDays;
}

class _Acc {
  double base = 0;
  bool boost = false;
  double bestImportance = -1;
  String bestStatement = '';
  String bestDifficulty = 'undergrad';
  final Map<String, double> perMaterial = {}; // material → max importance counted
  final Map<String, double> recency = {};
}

/// Returns the number of active concepts.
int recomputeUserActiveConcepts(AppDatabase db, {DateTime? now}) {
  final t = now ?? DateTime.now().toUtc();
  final rows = db.select('''
    SELECT mc.concept_id, mc.importance, mc.statement, mc.difficulty,
           m.id AS material_id, m.created_at, m.exam_date
    FROM material_concepts mc JOIN materials m ON m.id = mc.material_id
    WHERE m.status = 'active'
  ''');

  final acc = <String, _Acc>{};
  for (final r in rows) {
    final a = acc.putIfAbsent(r['concept_id'] as String, _Acc.new);
    final materialId = r['material_id'] as String;
    final importance = (r['importance'] as num).toDouble();
    final rf = a.recency[materialId] ??= recencyFactor(
      DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int, isUtc: true),
      t,
    );
    // Duplicate rows for one concept within one material count once (max importance).
    final prev = a.perMaterial[materialId];
    if (prev == null || importance > prev) {
      a.base += (importance - (prev ?? 0)) * rf;
      a.perMaterial[materialId] = importance;
    }
    a.boost = a.boost || examIsNear(r['exam_date'] as String?, t);
    if (importance > a.bestImportance) {
      a.bestImportance = importance;
      a.bestStatement = r['statement'] as String;
      a.bestDifficulty = r['difficulty'] as String;
    }
  }

  db.transaction(() {
    // Derived cache, not user data: rebuilding it deletes nothing the user owns.
    db.execute('DELETE FROM user_active_concepts');
    for (final e in acc.entries) {
      final a = e.value;
      db.execute(
        'INSERT INTO user_active_concepts (concept_id, priority, best_statement, best_difficulty, '
        'source_material_ids, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        [
          e.key,
          a.base * (a.boost ? examBoost : 1.0),
          a.bestStatement,
          a.bestDifficulty,
          jsonList(a.perMaterial.keys.toList()..sort()),
          t.millisecondsSinceEpoch,
        ],
      );
    }
  });
  return acc.length;
}
