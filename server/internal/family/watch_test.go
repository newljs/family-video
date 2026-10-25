package family

import "testing"

func TestWatchReportAndStats(t *testing.T) {
	a := testApp(t)
	seed(t, a, "w1", true)
	seed(t, a, "w2", true)

	// 首次上报：一次播放、30 秒观看。
	object(t, request(t, a, "POST", "/api/watch", "child", map[string]any{
		"reports": []map[string]any{
			{"video_id": "w1", "watched_ms": 30000, "played": true, "completed": false},
		},
	}))
	// 第二次上报：续看 20 秒并完播，验证增量聚合。
	object(t, request(t, a, "POST", "/api/watch", "child", map[string]any{
		"reports": []map[string]any{
			{"video_id": "w1", "watched_ms": 20000, "played": false, "completed": true},
		},
	}))
	items := list(t, request(t, a, "GET", "/api/videos", "parent", nil))
	byID := map[string]map[string]any{}
	for _, item := range items {
		byID[item["id"].(string)] = item
	}
	if byID["w1"]["plays"] != float64(1) || byID["w1"]["watched_ms"] != float64(50000) ||
		byID["w1"]["completed_count"] != float64(1) {
		t.Fatalf("w1 stats wrong: %v", byID["w1"])
	}
	if byID["w2"]["plays"] != float64(0) || byID["w2"]["completed_count"] != float64(0) {
		t.Fatalf("w2 should have zero stats: %v", byID["w2"])
	}

	// 删除视频后统计级联清理，且不再出现在列表里。
	if w := request(t, a, "DELETE", "/api/videos/w1", "parent", nil); w.Code != 200 {
		t.Fatalf("delete status %d", w.Code)
	}
	var count int
	if err := a.DB.QueryRow("SELECT COUNT(*) FROM watch_stats WHERE video_id='w1'").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatal("watch stats should cascade on video delete")
	}
}

func TestWatchReportValidation(t *testing.T) {
	a := testApp(t)
	seed(t, a, "w1", true)
	// 非法 id 与不存在视频被跳过，存在的正常记录，不报错。
	object(t, request(t, a, "POST", "/api/watch", "child", map[string]any{
		"reports": []map[string]any{
			{"video_id": "../escape", "watched_ms": 1000, "played": true},
			{"video_id": "missing-video", "watched_ms": 1000, "played": true},
			{"video_id": "w1", "watched_ms": 1000, "played": true},
		},
	}))
	var count int
	if err := a.DB.QueryRow("SELECT COUNT(*) FROM watch_stats").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("only the existing video should be recorded, got %d", count)
	}
	big := make([]map[string]any, 51)
	for i := range big {
		big[i] = map[string]any{"video_id": "w1", "watched_ms": 1}
	}
	if w := request(t, a, "POST", "/api/watch", "child", map[string]any{"reports": big}); w.Code != 400 {
		t.Fatalf("oversized batch should 400, got %d", w.Code)
	}
}
