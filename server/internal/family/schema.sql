
CREATE TABLE IF NOT EXISTS videos (
 id TEXT PRIMARY KEY, title TEXT NOT NULL, source_url TEXT,
 description TEXT NOT NULL DEFAULT '', stream_state TEXT NOT NULL DEFAULT 'pending',
 published INTEGER NOT NULL DEFAULT 1, path TEXT NOT NULL,
 duration REAL NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS tasks (
 id TEXT PRIMARY KEY, source TEXT NOT NULL, title TEXT NOT NULL,
 share_text TEXT NOT NULL DEFAULT '', title_manual INTEGER NOT NULL DEFAULT 0,
 kind TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'queued',
 error TEXT, video_id TEXT, attempts INTEGER NOT NULL DEFAULT 0,
 phase TEXT NOT NULL DEFAULT 'queued', downloaded_bytes INTEGER NOT NULL DEFAULT 0,
 total_bytes INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL DEFAULT 0,
 auto_retries INTEGER NOT NULL DEFAULT 0, error_code TEXT,
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
CREATE TABLE IF NOT EXISTS video_deletions (
 id TEXT PRIMARY KEY, path TEXT NOT NULL, source_url TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS watch_stats (
 video_id TEXT PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
 plays INTEGER NOT NULL DEFAULT 0,
 watched_ms INTEGER NOT NULL DEFAULT 0,
 completed INTEGER NOT NULL DEFAULT 0,
 last_watched_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS app_settings (
 key TEXT PRIMARY KEY, value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS watch_days (
 day TEXT PRIMARY KEY,
 watched_ms INTEGER NOT NULL DEFAULT 0,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS watch_events (
 event_id TEXT PRIMARY KEY, day TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS watch_events_day ON watch_events(day);
CREATE TABLE IF NOT EXISTS video_sources (
 video_id TEXT PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
 platform TEXT NOT NULL, source_id TEXT NOT NULL,
 UNIQUE(platform, source_id)
);
CREATE TABLE IF NOT EXISTS video_catalog (
 video_id TEXT PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
 category TEXT NOT NULL, search_text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS video_catalog_category ON video_catalog(category, video_id);
CREATE TABLE IF NOT EXISTS video_tags (
 video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
 tag TEXT NOT NULL, PRIMARY KEY(video_id, tag)
);
CREATE INDEX IF NOT EXISTS video_tags_tag ON video_tags(tag, video_id);
CREATE TABLE IF NOT EXISTS client_watch_stats (
 client_id TEXT NOT NULL,
 video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
 plays INTEGER NOT NULL DEFAULT 0,
 watched_ms INTEGER NOT NULL DEFAULT 0,
 completed INTEGER NOT NULL DEFAULT 0,
 last_watched_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 PRIMARY KEY(client_id, video_id)
);
CREATE INDEX IF NOT EXISTS client_watch_completed ON client_watch_stats(client_id, completed);
CREATE TABLE IF NOT EXISTS client_watch_days (
 client_id TEXT NOT NULL,
 day TEXT NOT NULL,
 watched_ms INTEGER NOT NULL DEFAULT 0,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 PRIMARY KEY(client_id, day)
);
CREATE TABLE IF NOT EXISTS client_watch_events (
 client_id TEXT NOT NULL,
 event_id TEXT NOT NULL,
 day TEXT NOT NULL,
 PRIMARY KEY(client_id, event_id)
);
CREATE INDEX IF NOT EXISTS client_watch_events_day ON client_watch_events(client_id, day);
