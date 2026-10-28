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
	tx, err := a.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	const upsert = `INSERT INTO watch_stats(video_id, plays, watched_ms, completed, last_watched_at)
VALUES(?,?,?,?,CURRENT_TIMESTAMP)
ON CONFLICT(video_id) DO UPDATE SET
 plays=plays+excluded.plays,
 watched_ms=watched_ms+excluded.watched_ms,
 completed=completed+excluded.completed,
 last_watched_at=CURRENT_TIMESTAMP`
	now := time.Now()
	day := now.Format("2006-01-02")
	oldest := now.AddDate(0, 0, -31).Format("2006-01-02")
	watchedDays := map[string]int64{}
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
		if report.EventID != "" {
			if len(report.EventID) > 64 || !safeVideoID.MatchString(report.EventID) {
				continue
			}
			result, err := tx.Exec("INSERT OR IGNORE INTO watch_events(event_id,day) VALUES(?,?)", report.EventID, reportDay)
			if err != nil {
				return err
			}
			if count, _ := result.RowsAffected(); count == 0 {
				continue // 回执与统计在同一事务中，响应丢失后重试不会重复扣额度。
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
		if _, err := tx.Exec(upsert, report.VideoID, plays, report.WatchedMS, completed); err != nil {
			return err
		}
		watchedDays[reportDay] += report.WatchedMS
	}
	for reportDay, watched := range watchedDays {
		if watched == 0 {
			continue
		}
		if _, err = tx.Exec(`INSERT INTO watch_days(day,watched_ms) VALUES(?,?)
ON CONFLICT(day) DO UPDATE SET watched_ms=watched_ms+excluded.watched_ms, updated_at=CURRENT_TIMESTAMP`, reportDay, watched); err != nil {
			return err
		}
	}
	if _, err = tx.Exec("DELETE FROM watch_days WHERE day < ?", oldest); err != nil {
		return err
	}
	if _, err = tx.Exec("DELETE FROM watch_events WHERE day < ?", oldest); err != nil {
		return err
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
	reply(w, 200, watchBudget(a.DB, limit, afterLimit))
	return nil
}
