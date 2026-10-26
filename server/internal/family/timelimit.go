package family

// 儿童端每日观看时长限制：家长端写入限额（0 表示不限制），儿童端读取剩余额度。
// 观看时长以服务端 watch_days 按天累计的真实上报为准，客户端本地计数仅作过渡显示。
// 达到限额后不做任何提示，而是安静收缩：儿童角色看到的目录只剩家长指定的合集
// （未指定则全部隐藏），当前正在播放的视频经已签发地址自然播完。

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"
	"time"
)

const dailyLimitKey = "daily_limit_minutes"
const afterLimitKey = "after_limit_collection_id"

func today() string { return time.Now().Format("2006-01-02") }

func (a *App) timeLimitMinutes() (int, error) {
	var value string
	err := a.DB.QueryRow("SELECT value FROM app_settings WHERE key=?", dailyLimitKey).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(value)
}

func (a *App) afterLimitCollection() (string, error) {
	var value string
	err := a.DB.QueryRow("SELECT value FROM app_settings WHERE key=?", afterLimitKey).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return value, err
}

// watchBudget 返回今日额度视图：限额、今天已看毫秒数、日期与额度状态。
func watchBudget(db *sql.DB, limit int, afterLimit string) map[string]any {
	var watched int64
	day := today()
	if err := db.QueryRow("SELECT watched_ms FROM watch_days WHERE day=?", day).Scan(&watched); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return map[string]any{"limit_minutes": limit, "watched_ms_today": 0, "day": day, "after_limit_collection_id": afterLimit, "exhausted": false}
	}
	return map[string]any{
		"limit_minutes":             limit,
		"watched_ms_today":          watched,
		"day":                       day,
		"after_limit_collection_id": afterLimit,
		"exhausted":                 limit > 0 && watched >= int64(limit)*60000,
	}
}

func (a *App) timeLimit(w http.ResponseWriter, r *http.Request, _ string) error {
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

func (a *App) saveTimeLimit(w http.ResponseWriter, r *http.Request, _ string) error {
	var b struct {
		LimitMinutes           int    `json:"limit_minutes"`
		AfterLimitCollectionID string `json:"after_limit_collection_id"`
	}
	if err := decode(r, &b); err != nil {
		return err
	}
	if b.LimitMinutes < 0 || b.LimitMinutes > 720 {
		return fail(400, "每日时长需在 0-720 分钟之间，0 表示不限制")
	}
	if len(b.AfterLimitCollectionID) > 64 {
		return fail(400, "合集标识无效")
	}
	if b.AfterLimitCollectionID != "" {
		var exists int
		if err := a.DB.QueryRow("SELECT COUNT(*) FROM collections WHERE id=?", b.AfterLimitCollectionID).Scan(&exists); err != nil {
			return err
		}
		if exists == 0 {
			return fail(400, "指定的合集不存在")
		}
	}
	if _, err := a.DB.Exec(`INSERT INTO app_settings(key,value) VALUES(?,?)
ON CONFLICT(key) DO UPDATE SET value=excluded.value`, dailyLimitKey, strconv.Itoa(b.LimitMinutes)); err != nil {
		return err
	}
	if _, err := a.DB.Exec(`INSERT INTO app_settings(key,value) VALUES(?,?)
ON CONFLICT(key) DO UPDATE SET value=excluded.value`, afterLimitKey, b.AfterLimitCollectionID); err != nil {
		return err
	}
	reply(w, 200, watchBudget(a.DB, b.LimitMinutes, b.AfterLimitCollectionID))
	return nil
}

// quietState 报告安静模式：当日限额用完即激活。collectionID 为家长指定的
// 合集，可为空（此时儿童端目录整体隐藏）。
func (a *App) quietState() (active bool, collectionID string, err error) {
	limit, err := a.timeLimitMinutes()
	if err != nil || limit <= 0 {
		return false, "", err
	}
	var watched int64
	day := today()
	if err := a.DB.QueryRow("SELECT watched_ms FROM watch_days WHERE day=?", day).Scan(&watched); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, "", nil
		}
		return false, "", err
	}
	if watched < int64(limit)*60000 {
		return false, "", nil
	}
	collectionID, err = a.afterLimitCollection()
	return true, collectionID, err
}
