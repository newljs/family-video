package family

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http/httptest"
	"testing"
)

func requestForClient(t *testing.T, a *App, method, path, role, client string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var data io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		data = bytes.NewReader(raw)
	}
	r := httptest.NewRequest(method, path, data)
	if role != "" {
		r.Header.Set("X-Family-Client", role)
	}
	if client != "" {
		r.Header.Set("X-Family-Client-Id", client)
	}
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	return w
}

func TestClientWatchStatsAndBudgetsAreIsolated(t *testing.T) {
	a := testApp(t)
	seed(t, a, "v1", true)
	seed(t, a, "v2", true)
	object(t, requestForClient(t, a, "POST", "/api/watch", "child", "client-a", map[string]any{
		"reports": []map[string]any{{"event_id": "a1", "day": today(), "video_id": "v1", "watched_ms": 30000, "played": true}},
	}))
	object(t, requestForClient(t, a, "POST", "/api/watch", "child", "client-b", map[string]any{
		"reports": []map[string]any{{"event_id": "b1", "day": today(), "video_id": "v2", "watched_ms": 5000, "played": true}},
	}))

	byID := func(role, client string) map[string]map[string]any {
		items := list(t, requestForClient(t, a, "GET", "/api/videos", role, client, nil))
		result := map[string]map[string]any{}
		for _, item := range items {
			result[item["id"].(string)] = item
		}
		return result
	}
	aVideos, bVideos := byID("child", "client-a"), byID("child", "client-b")
	if aVideos["v1"]["plays"] != float64(1) || aVideos["v2"]["plays"] != float64(0) {
		t.Fatalf("client A stats mixed: %v", aVideos)
	}
	if bVideos["v2"]["plays"] != float64(1) || bVideos["v1"]["plays"] != float64(0) {
		t.Fatalf("client B stats mixed: %v", bVideos)
	}
	aBudget := object(t, requestForClient(t, a, "GET", "/api/settings/time-limit", "child", "client-a", nil))
	bBudget := object(t, requestForClient(t, a, "GET", "/api/settings/time-limit", "child", "client-b", nil))
	if aBudget["watched_ms_today"] != float64(30000) || bBudget["watched_ms_today"] != float64(5000) {
		t.Fatalf("client budgets mixed: A=%v B=%v", aBudget, bBudget)
	}
	parent := byID("parent", "")
	if parent["v1"]["plays"] != float64(1) || parent["v2"]["plays"] != float64(1) {
		t.Fatalf("global parent view lost aggregate stats: %v", parent)
	}
}

func TestClientWatchedStateResetsWhenWholeLibraryWasSeen(t *testing.T) {
	a := testApp(t)
	seed(t, a, "v1", true)
	seed(t, a, "v2", true)
	object(t, requestForClient(t, a, "POST", "/api/watch", "child", "client-a", map[string]any{
		"reports": []map[string]any{
			{"event_id": "a1", "day": today(), "video_id": "v1", "watched_ms": 10000, "played": true, "completed": true},
			{"event_id": "a2", "day": today(), "video_id": "v2", "watched_ms": 10000, "played": true, "completed": true},
		},
	}))
	var completed, plays int
	if err := a.DB.QueryRow("SELECT IFNULL(SUM(completed),0),IFNULL(SUM(plays),0) FROM client_watch_stats WHERE client_id='client-a'").Scan(&completed, &plays); err != nil {
		t.Fatal(err)
	}
	if completed != 0 || plays != 0 {
		t.Fatalf("client watched flags not reset: completed=%d plays=%d", completed, plays)
	}
	items := list(t, requestForClient(t, a, "GET", "/api/videos", "child", "client-a", nil))
	for _, item := range items {
		if item["completed_count"] != float64(0) || item["plays"] != float64(0) {
			t.Fatalf("feed still treats videos as watched: %v", item)
		}
	}
	budget := object(t, requestForClient(t, a, "GET", "/api/settings/time-limit", "child", "client-a", nil))
	if budget["watched_ms_today"] != float64(20000) {
		t.Fatalf("reset must not erase watched duration: %v", budget)
	}

	// Another client is unaffected by client A's reset.
	object(t, requestForClient(t, a, "POST", "/api/watch", "child", "client-b", map[string]any{
		"reports": []map[string]any{{"event_id": "b1", "day": today(), "video_id": "v1", "watched_ms": 1000, "played": true, "completed": true}},
	}))
	bItems := list(t, requestForClient(t, a, "GET", "/api/videos", "child", "client-b", nil))
	for _, item := range bItems {
		if item["id"] == "v1" && item["completed_count"] != float64(1) {
			t.Fatalf("client B state was reset by A: %v", item)
		}
	}
}

// requestForApp 在 requestForClient 的基础上允许携带客户端应用标识。
func requestForApp(t *testing.T, a *App, method, path, role, client, app string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var data io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		data = bytes.NewReader(raw)
	}
	r := httptest.NewRequest(method, path, data)
	if role != "" {
		r.Header.Set("X-Family-Client", role)
	}
	if client != "" {
		r.Header.Set("X-Family-Client-Id", client)
	}
	if app != "" {
		r.Header.Set("X-Family-App", app)
	}
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	return w
}
