import sqlite3
from contextlib import contextmanager

SCHEMA = """
CREATE TABLE IF NOT EXISTS videos (
 id TEXT PRIMARY KEY, title TEXT NOT NULL, source_url TEXT,
 published INTEGER NOT NULL DEFAULT 0, path TEXT NOT NULL,
 duration REAL NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS tasks (
 id TEXT PRIMARY KEY, source TEXT NOT NULL, title TEXT NOT NULL,
 kind TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'queued',
 error TEXT, video_id TEXT, attempts INTEGER NOT NULL DEFAULT 0,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS task_source_active ON tasks(source)
 WHERE state NOT IN ('failed','cancelled');
CREATE TABLE IF NOT EXISTS collections (
 id TEXT PRIMARY KEY, title TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS collection_items (
 collection_id TEXT NOT NULL REFERENCES collections(id),
 video_id TEXT NOT NULL REFERENCES videos(id), position INTEGER NOT NULL,
 PRIMARY KEY(collection_id, video_id)
);
CREATE TABLE IF NOT EXISTS devices (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
 revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS pairing (
 code TEXT PRIMARY KEY, expires INTEGER NOT NULL
);
PRAGMA user_version=1;
"""


@contextmanager
def connect(settings):
    db = sqlite3.connect(settings.database, timeout=15)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def initialize(settings):
    with connect(settings) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.executescript(SCHEMA)
