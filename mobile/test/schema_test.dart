import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/data/app_database.dart';

void main() {
  test('migrates, enforces checks, FTS5 + trigram indexes stay in sync', () {
    final db = AppDatabase.inMemory();
    expect(db.select('PRAGMA user_version').first.columnAt(0), 3);

    db.execute(
        "INSERT INTO videos (id, source, source_id, title, description, created_at) VALUES ('v1','youtube','abc','Integration by parts intro','A technique for integrals',0)");
    expect(db.select("SELECT rowid FROM videos_fts WHERE videos_fts MATCH 'integrals'").length, 1);
    db.execute("UPDATE videos SET title = 'Taylor series' WHERE id = 'v1'");
    expect(db.select("SELECT rowid FROM videos_fts WHERE videos_fts MATCH 'taylor'").length, 1);
    expect(db.select("SELECT rowid FROM videos_fts WHERE videos_fts MATCH 'parts'").length, 0);

    db.execute(
        "INSERT INTO concepts (id, canonical_name, aliases, type, subject) VALUES ('c1','Integration by Parts','[\"IBP\"]','technique','math')");
    db.execute(
        "INSERT INTO concepts (id, canonical_name, type, subject) VALUES ('c2','Product Rule','technique','math')");
    // Trigram match tolerates partial words; aliases are indexed too.
    expect(db.select("SELECT rowid FROM concepts_trgm WHERE names MATCH 'integrat'").length, 1);
    expect(db.select("SELECT rowid FROM concepts_trgm WHERE names MATCH 'IBP'").length, 1);
    expect(db.select("SELECT rowid FROM concepts_trgm WHERE names MATCH 'Product'").length, 1);

    expect(
      () => db.execute(
          "INSERT INTO videos (id, source, source_id, title, status, created_at) VALUES ('v2','youtube','x','t','bogus',0)"),
      throwsA(anything),
    );
    expect(() => db.execute("INSERT INTO video_concepts (video_id, concept_id) VALUES ('nope','c1')"),
        throwsA(anything)); // foreign keys on
  });

  test('v3: transcripts are keyword-searchable and stay in sync', () {
    final db = AppDatabase.inMemory();
    db.execute(
        "INSERT INTO videos (id, source, source_id, title, transcript, created_at) VALUES ('v1','youtube','a','Lecture 4','today we use the product rule backwards',0)");
    expect(db.select("SELECT rowid FROM videos_fts WHERE videos_fts MATCH 'backwards'").length, 1);
    db.execute("UPDATE videos SET transcript = 'nothing here' WHERE id = 'v1'");
    expect(db.select("SELECT rowid FROM videos_fts WHERE videos_fts MATCH 'backwards'").length, 0);
  });

  test('embedding blob round-trip', () {
    final v = List<double>.generate(384, (i) => i / 384);
    final back = decodeEmbedding(encodeEmbedding(v));
    expect(back.length, 384);
    expect(back[100], closeTo(100 / 384, 1e-6));
  });
}
