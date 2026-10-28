package family

import (
	"fmt"
	"testing"
)

func TestTaskPagesIncludeOldTasksAndFilterBeforePaging(t *testing.T) {
	a := testApp(t)
	for i := 0; i < 205; i++ {
		state := "completed"
		if i == 0 {
			state = "running"
		}
		if i == 1 || i == 2 {
			state = "failed"
		}
		if _, err := a.DB.Exec("INSERT INTO tasks(id,source,title,kind,state) VALUES(?,?,?,'douyin',?)", fmt.Sprint(i), fmt.Sprint(i), "任务", state); err != nil {
			t.Fatal(err)
		}
	}
	first := object(t, request(t, a, "GET", "/api/tasks?limit=20", "parent", nil))
	if first["total"] != float64(205) || first["active"] != float64(1) || len(first["items"].([]any)) != 20 {
		t.Fatal(first)
	}
	last := object(t, request(t, a, "GET", "/api/tasks?limit=20&offset=200", "parent", nil))
	if len(last["items"].([]any)) != 5 {
		t.Fatal(last)
	}
	failed := object(t, request(t, a, "GET", "/api/tasks?limit=1&filter=failed&offset=1", "parent", nil))
	if failed["total"] != float64(2) || failed["items"].([]any)[0].(map[string]any)["id"] != "1" {
		t.Fatal(failed)
	}
	processing := object(t, request(t, a, "GET", "/api/tasks?limit=20&filter=processing", "parent", nil))
	if processing["total"] != float64(1) {
		t.Fatal(processing)
	}
	// Existing clients still receive the historical array response.
	if len(list(t, request(t, a, "GET", "/api/tasks", "parent", nil))) != 200 {
		t.Fatal("legacy response changed")
	}
}

func TestVideoPagesSearchSortAndEmptyBounds(t *testing.T) {
	a := testApp(t)
	for i := 0; i < 30; i++ {
		id := fmt.Sprintf("v%02d", i)
		seed(t, a, id, false)
		if _, err := a.DB.Exec("UPDATE videos SET title=?,description=? WHERE id=?", id, "page-search", id); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := a.DB.Exec("INSERT INTO watch_stats(video_id,plays,watched_ms,completed) VALUES('v00',10,10000,2)"); err != nil {
		t.Fatal(err)
	}
	first := object(t, request(t, a, "GET", "/api/videos?limit=24", "parent", nil))
	if first["total"] != float64(30) || len(first["items"].([]any)) != 24 {
		t.Fatal(first)
	}
	last := object(t, request(t, a, "GET", "/api/videos?limit=24&offset=24", "parent", nil))
	if len(last["items"].([]any)) != 6 || last["items"].([]any)[0].(map[string]any)["id"] != "v05" {
		t.Fatal(last)
	}
	for _, sort := range []string{"most_played", "most_completed", "most_watched"} {
		page := object(t, request(t, a, "GET", "/api/videos?limit=1&search=PAGE-SEARCH&sort="+sort, "parent", nil))
		if page["total"] != float64(30) || page["items"].([]any)[0].(map[string]any)["id"] != "v00" {
			t.Fatal(page)
		}
	}
	page := object(t, request(t, a, "GET", "/api/videos?limit=24&search=v00", "parent", nil))
	item := page["items"].([]any)[0].(map[string]any)
	if page["total"] != float64(1) || item["media_url"] == nil || item["path"] != nil {
		t.Fatal(page)
	}
	empty := object(t, request(t, a, "GET", "/api/videos?limit=24&offset=99", "parent", nil))
	if len(empty["items"].([]any)) != 0 {
		t.Fatal(empty)
	}
	bounds := object(t, request(t, a, "GET", "/api/videos?limit=999&offset=-1", "parent", nil))
	if bounds["limit"] != float64(24) || bounds["offset"] != float64(0) {
		t.Fatal(bounds)
	}
}

func TestVideoPagesRespectChildQuietMode(t *testing.T) {
	a := testApp(t)
	seed(t, a, "one", true)
	seed(t, a, "two", true)
	col := object(t, request(t, a, "POST", "/api/collections", "parent", map[string]any{
		"title": "安静合集", "video_ids": []string{"one"},
	}))["id"]
	object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{
		"limit_minutes": 1, "after_limit_collection_id": col,
	}))
	object(t, request(t, a, "POST", "/api/watch", "child", map[string]any{
		"reports": []map[string]any{{"video_id": "one", "watched_ms": 60000, "played": true}},
	}))
	child := object(t, request(t, a, "GET", "/api/videos?limit=24", "child", nil))
	if child["total"] != float64(1) || child["items"].([]any)[0].(map[string]any)["id"] != "one" {
		t.Fatal(child)
	}
	parent := object(t, request(t, a, "GET", "/api/videos?limit=24", "parent", nil))
	if parent["total"] != float64(2) {
		t.Fatal(parent)
	}
	object(t, request(t, a, "PUT", "/api/settings/time-limit", "parent", map[string]any{"limit_minutes": 1}))
	hidden := object(t, request(t, a, "GET", "/api/videos?limit=24", "child", nil))
	if hidden["total"] != float64(0) || len(hidden["items"].([]any)) != 0 {
		t.Fatal(hidden)
	}
}
