import 'dart:convert';

import 'package:theoremfeed/data/app_database.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String addConcept(AppDatabase db, String name, {bool pool = false, String subject = 'math', int? poolOrder}) {
  final id = _uuid.v4();
  db.execute(
    'INSERT INTO concepts (id, canonical_name, aliases, type, subject, description, in_theorem_pool, pool_order) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    [id, name, '[]', 'theorem', subject, name, boolInt(pool), poolOrder],
  );
  return id;
}

String addVideo(AppDatabase db, String src,
    {bool short = false, bool pool = false, String status = 'active', String subject = 'math', int createdAt = 0}) {
  final id = _uuid.v4();
  db.execute(
    'INSERT INTO videos (id, source, source_id, title, duration_sec, is_short, is_theorem, subject, '
    'in_theorem_pool, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [id, 'youtube', src, 'Video $src', short ? 60 : 900, boolInt(short), boolInt(pool), subject, boolInt(pool),
     status, createdAt],
  );
  return id;
}

void tag(AppDatabase db, String videoId, String conceptId, {bool primary = true}) => db.execute(
      'INSERT INTO video_concepts (video_id, concept_id, confidence, is_primary) VALUES (?, ?, 1.0, ?)',
      [videoId, conceptId, boolInt(primary)],
    );

String addMaterial(AppDatabase db,
    {String title = 'Notes', String status = 'active', String? exam, DateTime? created}) {
  final id = _uuid.v4();
  db.execute(
    'INSERT INTO materials (id, title, file_hash, page_count, status, exam_date, created_at) VALUES (?, ?, ?, 10, ?, ?, ?)',
    [id, title, _uuid.v4(), status, exam, (created ?? DateTime.now().toUtc()).millisecondsSinceEpoch],
  );
  return id;
}

void addMaterialConcept(AppDatabase db, String materialId, String conceptId,
        {double importance = 0.8, String statement = 'stmt', String difficulty = 'undergrad'}) =>
    db.execute(
      'INSERT INTO material_concepts (id, material_id, concept_id, statement, difficulty, importance, '
      'prerequisites_mentioned) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [_uuid.v4(), materialId, conceptId, statement, difficulty, importance, jsonEncode([])],
    );
