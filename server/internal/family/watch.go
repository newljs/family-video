package family

// 儿童端播放统计上报与聚合。客户端批量上报增量，服务端 upsert 聚合，
// 视频删除时经外键级联清理统计。

import (
	"net/http"
)

type watchReport struct {
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
	for _, report := range body.Reports {
		if !safeVideoID.MatchString(report.VideoID) ||
			report.WatchedMS < 0 || report.WatchedMS > 24*3600*1000 {
			continue // 单条非法跳过，不影响其余上报
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
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	reply(w, 200, map[string]bool{"ok": true})
	return nil
}
