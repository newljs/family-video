package family

import "testing"

func TestTimeLimitDefaultsAndAccess(t *testing.T) {
	a := testApp(t)
	// 未设置时限额为 0（不限制），今日无观看。
	limit := object(t, request(t, a, "GET", "/api/settings/time-limit", "child", nil))
	if limit["limit_minutes"] != float64(0) || limit["watched_ms_today"] != float64(0) {
		t.Fatalf("default limit wrong: %v", limit)
	}
	if day, _ := limit["day"].(string); len(day) != 10 {
		t.Fatalf("day should be a date string: %v", limit)
	}
	// 儿童端不能改限额，家长端可以。
	if w := request(t, a, "PUT", "/api/settings/time-limit", "child", map[string]any{"limit_minutes": 30}); w.Code != 403 {
		t.Fatalf("child should not change limit, got %d", w.Code)
	}
	saved := object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{"limit_minutes": 30}))
	if saved["limit_minutes"] != float64(30) {
		t.Fatalf("save failed: %v", saved)
	}
	if got := object(t, request(t, a, "GET", "/api/settings/time-limit", "child", nil)); got["limit_minutes"] != float64(30) {
		t.Fatalf("limit not persisted: %v", got)
	}
	// 重复保存走 upsert 更新。
	object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{"limit_minutes": 45}))
	if got := object(t, request(t, a, "GET", "/api/settings/time-limit", "child", nil)); got["limit_minutes"] != float64(45) {
		t.Fatalf("limit not updated: %v", got)
	}
	// 超范围与 0（不限制）均被正确处理。
	for _, bad := range []int{-1, 721} {
		if w := request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{"limit_minutes": bad}); w.Code != 400 {
			t.Fatalf("limit %d should be rejected, got %d", bad, w.Code)
		}
	}
	object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{"limit_minutes": 0}))
	if got := object(t, request(t, a, "GET", "/api/settings/time-limit", "child", nil)); got["limit_minutes"] != float64(0) {
		t.Fatalf("unlimited should be 0: %v", got)
	}
	// 指定额度用完后的合集：不存在则拒绝，存在则保存，空串清除。
	if w := request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{"limit_minutes": 20, "after_limit_collection_id": "missing"}); w.Code != 400 {
		t.Fatalf("unknown collection should be rejected, got %d", w.Code)
	}
	colID := object(t, request(t, a, "POST", "/api/collections", "parent", map[string]any{"title": "睡前合集", "video_ids": []string{}}))["id"].(string)
	after := object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{"limit_minutes": 20, "after_limit_collection_id": colID}))
	if after["after_limit_collection_id"] != colID {
		t.Fatalf("after limit collection not saved: %v", after)
	}
	object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{"limit_minutes": 20, "after_limit_collection_id": ""}))
	if got := object(t, request(t, a, "GET", "/api/settings/time-limit", "child", nil)); got["after_limit_collection_id"] != "" {
		t.Fatalf("after limit collection not cleared: %v", got)
	}
}

func TestQuietModeFiltersChildCatalogAfterLimit(t *testing.T) {
	a := testApp(t)
	seed(t, a, "w1", true)
	seed(t, a, "w2", true)
	colID := object(t, request(t, a, "POST", "/api/collections", "parent", map[string]any{
		"title":     "睡前合集",
		"video_ids": []string{"w1"},
	}))["id"].(string)
	object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{
		"limit_minutes":             10,
		"after_limit_collection_id": colID,
	}))

	// 未到限额：儿童看到全部内容。
	if items := list(t, request(t, a, "GET", "/api/videos", "child", nil)); len(items) != 2 {
		t.Fatalf("before limit child should see all videos: %d", len(items))
	}
	// 上报满 10 分钟，额度用完：儿童只剩指定合集里的视频，家长不受影响。
	object(t, request(t, a, "POST", "/api/watch", "child", map[string]any{
		"reports": []map[string]any{{"video_id": "w1", "watched_ms": 10 * 60000, "played": true}},
	}))
	if got := object(t, request(t, a, "GET", "/api/settings/time-limit", "child", nil)); got["exhausted"] != true {
		t.Fatalf("budget should be exhausted: %v", got)
	}
	items := list(t, request(t, a, "GET", "/api/videos", "child", nil))
	if len(items) != 1 || items[0]["id"] != "w1" {
		t.Fatalf("quiet mode should expose only designated videos: %v", items)
	}
	if items := list(t, request(t, a, "GET", "/api/videos", "parent", nil)); len(items) != 2 {
		t.Fatalf("parent must always see the full library: %d", len(items))
	}
	cols := list(t, request(t, a, "GET", "/api/collections", "child", nil))
	if len(cols) != 1 || cols[0]["id"] != colID {
		t.Fatalf("quiet mode should expose only the designated collection: %v", cols)
	}
	if vids := cols[0]["videos"].([]any); len(vids) != 1 {
		t.Fatalf("designated collection keeps its videos: %v", vids)
	}

	// 未指定合集时：儿童目录整体隐藏，合集为空。
	object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{
		"limit_minutes":             10,
		"after_limit_collection_id": "",
	}))
	if items := list(t, request(t, a, "GET", "/api/videos", "child", nil)); len(items) != 0 {
		t.Fatalf("quiet mode without designation should hide everything: %v", items)
	}
	if cols := list(t, request(t, a, "GET", "/api/collections", "child", nil)); len(cols) != 0 {
		t.Fatalf("quiet mode without designation should hide collections: %v", cols)
	}
}

func TestWatchReportAccumulatesDailyUsage(t *testing.T) {
	a := testApp(t)
	seed(t, a, "w1", true)
	object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{"limit_minutes": 10}))
	// 上报 30 秒 + 20 秒，响应应带回今日累计与限额。
	first := object(t, request(t, a, "POST", "/api/watch", "child", map[string]any{
		"reports": []map[string]any{
			{"video_id": "w1", "watched_ms": 30000, "played": true},
		},
	}))
	if first["watched_ms_today"] != float64(30000) || first["limit_minutes"] != float64(10) {
		t.Fatalf("watch response missing budget: %v", first)
	}
	object(t, request(t, a, "POST", "/api/watch", "child", map[string]any{
		"reports": []map[string]any{
			{"video_id": "w1", "watched_ms": 20000, "completed": true},
		},
	}))
	got := object(t, request(t, a, "GET", "/api/settings/time-limit", "child", nil))
	if got["watched_ms_today"] != float64(50000) {
		t.Fatalf("daily usage wrong: %v", got)
	}
	var rows int
	if err := a.DB.QueryRow("SELECT COUNT(*) FROM watch_days").Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("expected a single day row, got %d", rows)
	}
	// 非法上报不计入今日用量。
	object(t, request(t, a, "POST", "/api/watch", "child", map[string]any{
		"reports": []map[string]any{
			{"video_id": "missing-video", "watched_ms": 99000, "played": true},
		},
	}))
	got = object(t, request(t, a, "GET", "/api/settings/time-limit", "child", nil))
	if got["watched_ms_today"] != float64(50000) {
		t.Fatalf("invalid reports must not count: %v", got)
	}
}

func TestTVClientSkipsQuietMode(t *testing.T) {
	a := testApp(t)
	seed(t, a, "w1", true)
	seed(t, a, "w2", true)
	colID := object(t, request(t, a, "POST", "/api/collections", "parent", map[string]any{
		"title":     "睡前合集",
		"video_ids": []string{"w1"},
	}))["id"].(string)
	object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{
		"limit_minutes":             10,
		"after_limit_collection_id": colID,
	}))

	// 电视端（X-Family-App: tv）额度用完：目录与合集不收缩，平板照常收缩。
	object(t, requestForClient(t, a, "POST", "/api/watch", "child", "tv-1", map[string]any{
		"reports": []map[string]any{{"event_id": "tv1", "day": today(), "video_id": "w2", "watched_ms": 10 * 60000, "played": true}},
	}))
	if got := object(t, requestForClient(t, a, "GET", "/api/settings/time-limit", "child", "tv-1", nil)); got["exhausted"] != true {
		t.Fatalf("tv budget should be exhausted: %v", got)
	}
	tvVideos := list(t, requestForApp(t, a, "GET", "/api/videos", "child", "tv-1", "tv", nil))
	if len(tvVideos) != 2 {
		t.Fatalf("tv client should keep the full catalog after limit: %d", len(tvVideos))
	}
	// 平板用自己的额度：同样上报满 10 分钟后进入安静收缩。
	object(t, requestForClient(t, a, "POST", "/api/watch", "child", "tab-1", map[string]any{
		"reports": []map[string]any{{"event_id": "tab1", "day": today(), "video_id": "w1", "watched_ms": 10 * 60000, "played": true}},
	}))
	tabVideos := list(t, requestForClient(t, a, "GET", "/api/videos", "child", "tab-1", nil))
	if len(tabVideos) != 1 || tabVideos[0]["id"] != "w1" {
		t.Fatalf("tablet quiet mode should expose only the designated videos: %v", tabVideos)
	}
	tvCols := list(t, requestForApp(t, a, "GET", "/api/collections", "child", "tv-1", "tv", nil))
	if len(tvCols) != 1 || tvCols[0]["id"] != colID {
		t.Fatalf("tv client should see every collection: %v", tvCols)
	}
	page := object(t, requestForApp(t, a, "GET", "/api/videos?limit=1&offset=0", "child", "tv-1", "tv", nil))
	if page["total"] != float64(2) {
		t.Fatalf("tv paged catalog should not shrink: %v", page)
	}
}
