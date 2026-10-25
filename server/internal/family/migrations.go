package family

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"time"
)

func migrate(db *sql.DB, c Config, version int) error {
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		return err
	}
	if version > 0 && version < 3 {
		// VACUUM INTO snapshots SQLite's committed WAL state, unlike copying the
		// database file while it is open. Never overwrite a previous backup.
		backup := filepath.Join(c.Data, "database", "before-v3-"+time.Now().UTC().Format("20060102-150405")+"-"+ID()[:8]+".sqlite3")
		if _, err := db.Exec("VACUUM INTO ?", backup); err != nil {
			return fmt.Errorf("升级前备份失败，数据库保持原状: %w", err)
		}
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec(schema); err != nil {
		return err
	}
	if version == 1 {
		for _, field := range []string{
			"phase TEXT NOT NULL DEFAULT 'queued'", "downloaded_bytes INTEGER NOT NULL DEFAULT 0",
			"total_bytes INTEGER NOT NULL DEFAULT 0", "next_attempt_at INTEGER NOT NULL DEFAULT 0",
			"auto_retries INTEGER NOT NULL DEFAULT 0", "error_code TEXT",
		} {
			if _, err = tx.Exec("ALTER TABLE tasks ADD COLUMN " + field); err != nil {
				return err
			}
		}
		if _, err = tx.Exec("UPDATE videos SET published=1; UPDATE tasks SET phase=state"); err != nil {
			return err
		}
	}
	if version > 0 && version < 3 {
		for _, statement := range []string{
			"ALTER TABLE videos ADD COLUMN description TEXT NOT NULL DEFAULT ''",
			"ALTER TABLE videos ADD COLUMN stream_state TEXT NOT NULL DEFAULT 'pending'",
			"ALTER TABLE tasks ADD COLUMN share_text TEXT NOT NULL DEFAULT ''",
			"ALTER TABLE tasks ADD COLUMN title_manual INTEGER NOT NULL DEFAULT 0",
		} {
			if _, err = tx.Exec(statement); err != nil {
				return err
			}
		}
		if _, err = tx.Exec("UPDATE tasks SET title_manual=1 WHERE title NOT IN ('','新收集的视频','本地视频')"); err != nil {
			return err
		}
	}
	if _, err = tx.Exec("PRAGMA user_version=3"); err != nil {
		return err
	}
	return tx.Commit()
}
