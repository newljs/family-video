package family

import (
	"database/sql"
	"errors"
	"net/http"
	"os"
	"path/filepath"
)

func (a *App) cancelImport(w http.ResponseWriter, r *http.Request, _ string) error {
	id := r.PathValue("id")
	tx, err := a.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var state, kind string
	err = tx.QueryRow("SELECT state,kind FROM tasks WHERE id=?", id).Scan(&state, &kind)
	if errors.Is(err, sql.ErrNoRows) {
		return fail(404, "任务不存在")
	}
	if err != nil {
		return err
	}
	if state == "completed" {
		return fail(409, "任务已完成，无法取消")
	}
	if _, err = tx.Exec("UPDATE tasks SET state='cancelled',phase='cancelled',next_attempt_at=0,error=NULL,error_code=NULL WHERE id=?", id); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	a.taskMu.Lock()
	cancel := a.activeTasks[id]
	if cancel != nil {
		cancel()
	}
	a.taskMu.Unlock()
	// Running workers clean up after their child process exits. Never remove a
	// file that FFmpeg/F2 may still have open.
	if state != "running" && cancel == nil {
		a.cleanupImport(id, kind)
	}
	reply(w, 200, map[string]bool{"ok": true})
	return nil
}

func (a *App) cleanupImport(id, kind string) {
	// Only generated task IDs may be used as local cleanup paths.
	if len(id) != 32 || filepath.Base(id) != id {
		return
	}
	for _, c := range id {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return
		}
	}
	if kind == "upload" {
		os.Remove(filepath.Join(a.Config.Data, "temp", id+".mp4"))
	}
	os.RemoveAll(filepath.Join(a.Config.Data, "temp", id))
}

func (a *App) updateCollection(w http.ResponseWriter, r *http.Request, _ string) error {
	var b struct {
		Title    string
		VideoIDs []string `json:"video_ids"`
	}
	if err := decode(r, &b); err != nil {
		return err
	}
	if !valid(b.Title, 100) || len(b.VideoIDs) > 500 {
		return fail(400, "合集内容格式无效")
	}
	tx, err := a.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.Exec("UPDATE collections SET title=? WHERE id=?", b.Title, r.PathValue("id"))
	if err != nil {
		return err
	}
	count, _ := result.RowsAffected()
	if count == 0 {
		return fail(404, "合集不存在")
	}
	if _, err = tx.Exec("DELETE FROM collection_items WHERE collection_id=?", r.PathValue("id")); err != nil {
		return err
	}
	seen := map[string]bool{}
	position := 0
	for _, id := range b.VideoIDs {
		if seen[id] {
			continue
		}
		seen[id] = true
		var n int
		if err = tx.QueryRow("SELECT COUNT(*) FROM videos WHERE id=?", id).Scan(&n); err != nil {
			return err
		}
		if n == 0 {
			return fail(400, "合集包含不存在的视频")
		}
		if _, err = tx.Exec("INSERT INTO collection_items VALUES(?,?,?)", r.PathValue("id"), id, position); err != nil {
			return err
		}
		position++
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	reply(w, 200, map[string]bool{"ok": true})
	return nil
}

func (a *App) deleteCollection(w http.ResponseWriter, r *http.Request, _ string) error {
	tx, err := a.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec("DELETE FROM collection_items WHERE collection_id=?", r.PathValue("id")); err != nil {
		return err
	}
	result, err := tx.Exec("DELETE FROM collections WHERE id=?", r.PathValue("id"))
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return fail(404, "合集不存在")
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	reply(w, 200, map[string]bool{"ok": true})
	return nil
}
