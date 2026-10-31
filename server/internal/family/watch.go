package family

// 儿童端播放统计上报与聚合。客户端批量上报增量，服务端 upsert 聚合，
// 视频删除时经外键级联清理统计。

import (
	"net/http"
	"time"
)

type watchReport struct {
	EventID   string `json:"event_id"`
	Day       string `json:"day"`
	VideoID   string `json:"video_id"`
	WatchedMS int64  `json:"watched_ms"`
	Played    bool   `json:"played"`
	Completed bool   `json:"completed"`
}

func (a *App) reportWatch(w http.ResponseWriter, r *http.Request, _ string) error {
	var body struct{ Reports []watchReport }
	if err := decode(r, &body); err != nil {
		return err
	}
	if len(body.Reports) == 0 || len(body.Reports) > 50 {
		return fail(400, "一次上报 1-50 条观看记录")
	}
	client := clientID(r)
	tx, err := a.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	const globalUpsert = `INSERT INTO watch_stats(video_id, plays, watched_ms, completed, last_watched_at)
VALUES(?,?,?,?,CURRENT_TIMESTAMP)
ON CONFLICT(video_id) DO UPDATE SET
 plays=plays+excluded.plays,
 watched_ms=watched_ms+excluded.watched_ms,
 completed=completed+excluded.completed,
 last_watched_at=CURRENT_TIMESTAMP`
	const clientUpsert = `INSERT INTO client_watch_stats(client_id,video_id,plays,watched_ms,completed,last_watched_at)
VALUES(?,?,?,?,?,CURRENT_TIMESTAMP)
ON CONFLICT(client_id,video_id) DO UPDATE SET
 plays=plays+excluded.plays,
 watched_ms=watched_ms+excluded.watched_ms,
 completed=completed+excluded.completed,
 last_watched_at=CURRENT_TIMESTAMP`
	now := time.Now()
	day := now.Format("2006-01-02")
	oldest := now.AddDate(0, 0, -31).Format("2006-01-02")
	globalDays := map[string]int64{}
	clientDays := map[string]int64{}
	for _, report := range body.Reports {
		if !safeVideoID.MatchString(report.VideoID) ||
			report.WatchedMS < 0 || report.WatchedMS > 24*3600*1000 {
			continue // 单条非法跳过，不影响其余上报
		}
		reportDay := report.Day
		if reportDay == "" {
			reportDay = day // 兼容旧客户端；新客户端始终携带事件 ID 和观看日期。
		}
		parsed, parseErr := time.Parse("2006-01-02", reportDay)
		if parseErr != nil || parsed.Format("2006-01-02") != reportDay || reportDay < oldest || reportDay > day {
			continue
		}
		globalNew := true
		if report.EventID != "" {
			if len(report.EventID) > 64 || !safeVideoID.MatchString(report.EventID) {
				continue
			}
			if client != "" {
				result, err := tx.Exec("INSERT OR IGNORE INTO client_watch_events(client_id,event_id,day) VALUES(?,?,?)", client, report.EventID, reportDay)
				if err != nil {
					return err
				}
				if count, _ := result.RowsAffected(); count == 0 {
					continue // 该客户端已处理过此事件。
				}
			}
			result, err := tx.Exec("INSERT OR IGNORE INTO watch_events(event_id,day) VALUES(?,?)", report.EventID, reportDay)
			if err != nil {
				return err
			}
			if count, _ := result.RowsAffected(); count == 0 {
				if client == "" {
					continue // 旧客户端继续保持原有去重语义。
				}
				globalNew = false // 全局已计过，但仍要为这个客户端计一次。
			}
		}
		var exists int
		if err := tx.QueryRow("SELECT COUNT(*) FROM videos WHERE id=?", report.VideoID).Scan(&exists); err != nil {
			return err
		}
		if exists == 0 {
			continue // 视频可能刚被删除，忽略该条
		}
		plays, completed := 0, 0
		if report.Played {
			plays = 1
		}
		if report.Completed {
			completed = 1
		}
		if globalNew {
			if _, err := tx.Exec(globalUpsert, report.VideoID, plays, report.WatchedMS, completed); err != nil {
				return err
			}
			globalDays[reportDay] += report.WatchedMS
		}
		if client != "" {
			if _, err := tx.Exec(clientUpsert, client, report.VideoID, plays, report.WatchedMS, completed); err != nil {
				return err
			}
			clientDays[reportDay] += report.WatchedMS
		}
	}
	for reportDay, watched := range globalDays {
		if watched == 0 {
			continue
		}
		if _, err = tx.Exec(`INSERT INTO watch_days(day,watched_ms) VALUES(?,?)
ON CONFLICT(day) DO UPDATE SET watched_ms=watched_ms+excluded.watched_ms, updated_at=CURRENT_TIMESTAMP`, reportDay, watched); err != nil {
			return err
		}
	}
	for reportDay, watched := range clientDays {
		if watched == 0 {
			continue
		}
		if _, err = tx.Exec(`INSERT INTO client_watch_days(client_id,day,watched_ms) VALUES(?,?,?)
ON CONFLICT(client_id,day) DO UPDATE SET watched_ms=watched_ms+excluded.watched_ms, updated_at=CURRENT_TIMESTAMP`, client, reportDay, watched); err != nil {
			return err
		}
	}
	if _, err = tx.Exec("DELETE FROM watch_days WHERE day < ?", oldest); err != nil {
		return err
	}
	if _, err = tx.Exec("DELETE FROM watch_events WHERE day < ?", oldest); err != nil {
		return err
	}
	if client != "" {
		if _, err = tx.Exec("DELETE FROM client_watch_days WHERE client_id=? AND day < ?", client, oldest); err != nil {
			return err
		}
		if _, err = tx.Exec("DELETE FROM client_watch_events WHERE client_id=? AND day < ?", client, oldest); err != nil {
			return err
		}
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	limit, err := a.timeLimitMinutes()
	if err != nil {
		return err
	}
	afterLimit, err := a.afterLimitCollection()
	if err != nil {
		return err
	}
	budget := watchBudget(a.DB, limit, afterLimit, client)
	if client != "" {
		if reset, e := a.resetClientIfAllWatched(client); e == nil && reset {
			budget["watched_reset"] = true
		}
	}
	reply(w, 200, budget)
	return nil
}

// resetClientIfAllWatched keeps per-client watched time for analytics but
// clears plays/completed once every video in the current library was seen.
func (a *App) resetClientIfAllWatched(client string) (bool, error) {
	if client == "" {
		return false, nil
	}
	tx, err := a.DB.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var total, completed int
	if err = tx.QueryRow("SELECT COUNT(*) FROM videos").Scan(&total); err != nil {
		return false, err
	}
	if total == 0 {
		return false, nil
	}
	if err = tx.QueryRow("SELECT COUNT(*) FROM client_watch_stats WHERE client_id=? AND completed>0", client).Scan(&completed); err != nil {
		return false, err
	}
	if completed < total {
		return false, nil
	}
	if _, err = tx.Exec("UPDATE client_watch_stats SET plays=0, completed=0 WHERE client_id=?", client); err != nil {
		return false, err
	}
	if err = tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}
