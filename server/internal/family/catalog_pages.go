package family

import (
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func pageBounds(r *http.Request) (int, int) {
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > 200 {
		limit = 24
	}
	return offset, limit
}

// Counts and rows share a snapshot so a worker completion cannot split a page.
func (a *App) catalogPage(w http.ResponseWriter, r *http.Request, selectSQL, from, order string, args []any, videos bool, role string) error {
	offset, limit := pageBounds(r)
	tx, err := a.DB.BeginTx(r.Context(), nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var total, active int
	if err = tx.QueryRow("SELECT COUNT(*)"+from, args...).Scan(&total); err != nil {
		return err
	}
	if !videos {
		if err = tx.QueryRow("SELECT COUNT(*) FROM tasks WHERE state IN ('queued','running')").Scan(&active); err != nil {
			return err
		}
	}
	items, err := query(tx, selectSQL+from+" ORDER BY "+order+" LIMIT ? OFFSET ?", append(args, limit, offset)...)
	if err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	if videos {
		for _, v := range items {
			if name, _ := v["path"].(string); name != "" && filepath.Base(name) == name {
				if info, e := os.Stat(filepath.Join(a.Config.Data, "videos", name)); e == nil && !info.IsDir() {
					v["size_bytes"] = info.Size()
				}
			}
			a.present(v, role)
		}
	}
	reply(w, 200, map[string]any{"items": items, "total": total, "offset": offset, "limit": limit, "active": active})
	return nil
}

func (a *App) taskPage(w http.ResponseWriter, r *http.Request) error {
	from := " FROM tasks WHERE 1=1"
	switch r.URL.Query().Get("filter") {
	case "processing":
		from += " AND state IN ('queued','running')"
	case "failed":
		from += " AND state='failed'"
	case "completed":
		from += " AND state='completed'"
	}
	return a.catalogPage(w, r, "SELECT id,title,kind,state,phase,downloaded_bytes,total_bytes,error,error_code,video_id,attempts,auto_retries,next_attempt_at", from, "created_at DESC,rowid DESC", nil, false, "admin")
}

func (a *App) videoPage(w http.ResponseWriter, r *http.Request, role string) error {
	client := childClient(r, role)
	if client != "" {
		if _, err := a.resetClientIfAllWatched(client); err != nil {
			return err
		}
	}
	join, args := watchStatsJoin(client)
	from := " FROM videos v" + join + " WHERE 1=1"
	if role == "child" {
		quiet, id, err := a.quietState(client)
		if err != nil {
			return err
		}
		if quiet {
			from += " AND v.id IN (SELECT video_id FROM collection_items WHERE collection_id=?)"
			args = append(args, id)
		}
	}
	if search := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("search"))); search != "" {
		from += " AND instr(lower(v.title || ' ' || COALESCE(v.description,'')),?)>0"
		args = append(args, search)
	}
	order := "v.created_at DESC,v.rowid DESC"
	switch r.URL.Query().Get("sort") {
	case "most_played":
		order = "IFNULL(s.plays,0) DESC," + order
	case "most_completed":
		order = "IFNULL(s.completed,0) DESC," + order
	case "most_watched":
		order = "IFNULL(s.watched_ms,0) DESC," + order
	}
	return a.catalogPage(w, r, "SELECT v.*,IFNULL(s.plays,0) AS plays,IFNULL(s.watched_ms,0) AS watched_ms,IFNULL(s.completed,0) AS completed_count,s.last_watched_at", from, order, args, true, role)
}
