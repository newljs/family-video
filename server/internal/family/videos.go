package family

import (
	"database/sql"
	"errors"
	"net/http"
	"os"
	"path/filepath"
)

func (a *App) deleteVideo(w http.ResponseWriter, r *http.Request, _ string) error {
	id := r.PathValue("id")
	a.mediaMu.Lock()
	defer a.mediaMu.Unlock()
	tx, err := a.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var name string
	var source sql.NullString
	err = tx.QueryRow("SELECT path,source_url FROM videos WHERE id=?", id).Scan(&name, &source)
	if errors.Is(err, sql.ErrNoRows) {
		return fail(404, "视频不存在或已删除")
	}
	if err != nil {
		return err
	}
	if filepath.Base(name) != name || !safeVideoID.MatchString(id) {
		return fail(400, "视频路径无效")
	}
	for _, stmt := range []string{"DELETE FROM collection_items WHERE video_id=?", "DELETE FROM tasks WHERE video_id=?", "DELETE FROM videos WHERE id=?"} {
		if _, err = tx.Exec(stmt, id); err != nil {
			return err
		}
	}
	if _, err = tx.Exec("INSERT INTO video_deletions(id,path,source_url) VALUES(?,?,?)", id, name, source.String); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	// A playing file may still be open on Windows; leave a persisted cleanup job
	// in that case. The directory and all signed routes are already inaccessible.
	a.cleanupDeleted()
	reply(w, 200, map[string]bool{"ok": true})
	return nil
}

func removeFile(path string) bool {
	err := os.Remove(path)
	return err == nil || os.IsNotExist(err)
}

func (a *App) cleanupDeleted() {
	items, err := query(a.DB, "SELECT id,path,source_url FROM video_deletions")
	if err != nil {
		return
	}
	for _, v := range items {
		id, name := v["id"].(string), v["path"].(string)
		if !safeVideoID.MatchString(id) || filepath.Base(name) != name {
			continue
		}
		videoOK := removeFile(filepath.Join(a.Config.Data, "videos", name))
		coverOK := removeFile(filepath.Join(a.Config.Data, "thumbnails", id+".jpg"))
		streamOK := os.RemoveAll(filepath.Join(a.Config.Data, "streams", id)) == nil
		source, _ := v["source_url"].(string)
		cacheOK := true
		if source != "" {
			a.cacheMu.Lock()
			key := sourceKey(source)
			cacheOK = removeFile(filepath.Join(a.Config.Data, "download-cache", key+".mp4"))
			cacheOK = removeFile(filepath.Join(a.Config.Data, "download-cache", key+".json")) && cacheOK
			a.cacheMu.Unlock()
		}
		if videoOK && coverOK && streamOK && cacheOK {
			a.DB.Exec("DELETE FROM video_deletions WHERE id=?", id)
		}
	}
}
