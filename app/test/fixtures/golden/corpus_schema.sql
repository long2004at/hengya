-- type=table name=chunks_fts tbl=chunks_fts
CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_id UNINDEXED, title, text, tokenize='trigram');

-- type=table name=chunks tbl=chunks
CREATE TABLE chunks (
  chunk_id    TEXT PRIMARY KEY,
  subject_id  TEXT NOT NULL,
  ppt_id      TEXT NOT NULL,
  deck        TEXT,
  page_start  INTEGER,
  page_end    INTEGER,
  title       TEXT,
  text        TEXT NOT NULL,
  source_type TEXT NOT NULL DEFAULT 'ppt',
  file_date   TEXT
);

-- type=table name=vectors tbl=vectors
CREATE TABLE vectors (
  chunk_id TEXT PRIMARY KEY REFERENCES chunks(chunk_id),
  dim      INTEGER NOT NULL,
  vec      BLOB NOT NULL,
  scale    REAL NOT NULL
);

-- type=table name=meta tbl=meta
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);

-- type=table name=chunk_state tbl=chunk_state
CREATE TABLE chunk_state (
  chunk_id    TEXT PRIMARY KEY,
  content_md5 TEXT,
  model       TEXT,
  ts          REAL
);

-- type=table name=deck_state tbl=deck_state
CREATE TABLE deck_state (
  subject_id TEXT NOT NULL,
  ppt_id     TEXT NOT NULL,
  source     TEXT NOT NULL DEFAULT 'tree',
  file_path  TEXT,
  file_md5   TEXT,
  chunk_count INTEGER NOT NULL DEFAULT 0,
  updated_at  TEXT,
  PRIMARY KEY (subject_id, ppt_id)
);

-- type=table name=chunks_fts_data tbl=chunks_fts_data
CREATE TABLE 'chunks_fts_data'(id INTEGER PRIMARY KEY, block BLOB);

-- type=table name=chunks_fts_idx tbl=chunks_fts_idx
CREATE TABLE 'chunks_fts_idx'(segid, term, pgno, PRIMARY KEY(segid, term)) WITHOUT ROWID;

-- type=table name=chunks_fts_content tbl=chunks_fts_content
CREATE TABLE 'chunks_fts_content'(id INTEGER PRIMARY KEY, c0, c1, c2);

-- type=table name=chunks_fts_docsize tbl=chunks_fts_docsize
CREATE TABLE 'chunks_fts_docsize'(id INTEGER PRIMARY KEY, sz BLOB);

-- type=table name=chunks_fts_config tbl=chunks_fts_config
CREATE TABLE 'chunks_fts_config'(k PRIMARY KEY, v) WITHOUT ROWID;
