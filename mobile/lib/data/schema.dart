/// On-device SQLite schema: the §5 data model, ported from Postgres.
///
/// Port notes:
///   * UUIDs are TEXT; booleans are INTEGER 0/1; timestamps are epoch-ms INTEGER;
///     dates (exam_date) are 'YYYY-MM-DD' TEXT; arrays are JSON TEXT.
///   * Embeddings (384-d all-MiniLM-L6-v2) are little-endian float32 BLOBs. The
///     library is personal-scale (hundreds to low thousands of rows), so exact
///     cosine in Dart replaces pgvector's HNSW.
///   * `videos_fts` (FTS5, BM25) replaces the tsvector + GIN index.
///   * `concepts_trgm` (FTS5 trigram tokenizer) replaces pg_trgm for fuzzy lookup.
///   * `concepts.pool_order` gives the theorem pool its curated order (§7).
///
/// Soft-delete only: user data changes status, it is never DELETEd.
library;

const int schemaVersion = 1;

const List<String> migrationV1 = [
  '''
  CREATE TABLE videos (
    id              TEXT PRIMARY KEY,
    source          TEXT NOT NULL CHECK (source IN ('youtube','local','manim')),
    source_id       TEXT NOT NULL UNIQUE,
    title           TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',
    transcript      TEXT NOT NULL DEFAULT '',
    duration_sec    INTEGER,
    thumbnail_url   TEXT,
    is_short        INTEGER NOT NULL DEFAULT 0,
    is_theorem      INTEGER NOT NULL DEFAULT 0,
    subject         TEXT CHECK (subject IS NULL OR subject IN ('math','physics','cs')),
    in_theorem_pool INTEGER NOT NULL DEFAULT 0,
    embedding       BLOB,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','rejected_edu','rejected_lang','rejected_safety')),
    created_at      INTEGER NOT NULL
  )''',
  'CREATE INDEX ix_videos_feed ON videos (status, is_short, in_theorem_pool)',
  '''
  CREATE VIRTUAL TABLE videos_fts USING fts5(
    title, description, content='videos', content_rowid='rowid', tokenize='porter unicode61'
  )''',
  '''
  CREATE TRIGGER videos_ai AFTER INSERT ON videos BEGIN
    INSERT INTO videos_fts(rowid, title, description) VALUES (new.rowid, new.title, new.description);
  END''',
  '''
  CREATE TRIGGER videos_au AFTER UPDATE OF title, description ON videos BEGIN
    INSERT INTO videos_fts(videos_fts, rowid, title, description)
      VALUES ('delete', old.rowid, old.title, old.description);
    INSERT INTO videos_fts(rowid, title, description) VALUES (new.rowid, new.title, new.description);
  END''',
  '''
  CREATE TABLE concepts (
    id              TEXT PRIMARY KEY,
    canonical_name  TEXT NOT NULL UNIQUE COLLATE NOCASE,
    aliases         TEXT NOT NULL DEFAULT '[]',
    type            TEXT NOT NULL CHECK (type IN ('theorem','definition','formula','technique','concept')),
    subject         TEXT NOT NULL CHECK (subject IN ('math','physics','cs')),
    description     TEXT NOT NULL DEFAULT '',
    embedding       BLOB,
    in_theorem_pool INTEGER NOT NULL DEFAULT 0,
    pool_order      INTEGER
  )''',
  // rowid mirrors concepts.rowid; `names` = canonical name + aliases.
  "CREATE VIRTUAL TABLE concepts_trgm USING fts5(names, tokenize='trigram')",
  '''
  CREATE TRIGGER concepts_ai AFTER INSERT ON concepts BEGIN
    INSERT INTO concepts_trgm(rowid, names)
      VALUES (new.rowid, new.canonical_name || ' ' || coalesce((SELECT group_concat(value, ' ') FROM json_each(new.aliases)), ''));
  END''',
  '''
  CREATE TRIGGER concepts_au AFTER UPDATE OF canonical_name, aliases ON concepts BEGIN
    UPDATE concepts_trgm
      SET names = new.canonical_name || ' ' || coalesce((SELECT group_concat(value, ' ') FROM json_each(new.aliases)), '')
      WHERE rowid = new.rowid;
  END''',
  '''
  CREATE TABLE concept_edges (
    from_concept TEXT NOT NULL REFERENCES concepts(id),
    to_concept   TEXT NOT NULL REFERENCES concepts(id),
    relation     TEXT NOT NULL CHECK (relation IN ('requires','related','generalizes')),
    weight       REAL NOT NULL DEFAULT 1.0,
    PRIMARY KEY (from_concept, to_concept, relation)
  )''',
  '''
  CREATE TABLE video_concepts (
    video_id   TEXT NOT NULL REFERENCES videos(id),
    concept_id TEXT NOT NULL REFERENCES concepts(id),
    confidence REAL NOT NULL DEFAULT 1.0,
    is_primary INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (video_id, concept_id)
  )''',
  'CREATE INDEX ix_video_concepts_concept_id ON video_concepts (concept_id)',
  '''
  CREATE TABLE materials (
    id         TEXT PRIMARY KEY,
    title      TEXT NOT NULL,
    file_hash  TEXT NOT NULL UNIQUE,
    page_count INTEGER NOT NULL,
    status     TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived','deleted')),
    exam_date  TEXT,
    created_at INTEGER NOT NULL
  )''',
  '''
  CREATE TABLE material_concepts (
    id                      TEXT PRIMARY KEY,
    material_id             TEXT NOT NULL REFERENCES materials(id),
    concept_id              TEXT NOT NULL REFERENCES concepts(id),
    statement               TEXT NOT NULL,
    latex                   TEXT,
    chapter                 TEXT,
    section                 TEXT,
    difficulty              TEXT NOT NULL CHECK (difficulty IN ('highschool','undergrad','advanced')),
    importance              REAL NOT NULL CHECK (importance >= 0 AND importance <= 1),
    prerequisites_mentioned TEXT NOT NULL DEFAULT '[]'
  )''',
  'CREATE INDEX ix_material_concepts_material_id ON material_concepts (material_id)',
  '''
  CREATE TABLE user_active_concepts (
    concept_id          TEXT PRIMARY KEY REFERENCES concepts(id),
    priority            REAL NOT NULL,
    best_statement      TEXT NOT NULL,
    best_difficulty     TEXT NOT NULL,
    source_material_ids TEXT NOT NULL DEFAULT '[]',
    updated_at          INTEGER NOT NULL
  )''',
  '''
  CREATE TABLE watch_history (
    id              TEXT PRIMARY KEY,
    video_id        TEXT NOT NULL REFERENCES videos(id),
    watched_sec     INTEGER NOT NULL DEFAULT 0,
    completed       INTEGER NOT NULL DEFAULT 0,
    rewatched_count INTEGER NOT NULL DEFAULT 0,
    saved           INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL
  )''',
  'CREATE INDEX ix_watch_history_video_id ON watch_history (video_id)',
  '''
  CREATE TABLE video_resolutions (
    video_id    TEXT PRIMARY KEY REFERENCES videos(id),
    payload     TEXT NOT NULL,
    resolved_at INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL
  )''',
  '''
  CREATE TABLE relevance_scores (
    video_id        TEXT NOT NULL REFERENCES videos(id),
    concept_id      TEXT NOT NULL REFERENCES concepts(id),
    topic_fit       REAL NOT NULL,
    level_fit       REAL NOT NULL,
    depth_fit       REAL NOT NULL,
    prerequisite_ok REAL NOT NULL,
    final           REAL NOT NULL,
    reason          TEXT NOT NULL DEFAULT '',
    judged_at       INTEGER NOT NULL,
    PRIMARY KEY (video_id, concept_id)
  )''',
  '''
  CREATE TABLE search_cache (
    query_hash TEXT PRIMARY KEY,
    query_text TEXT NOT NULL,
    results    TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
  )''',
];
