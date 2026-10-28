package family

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWatchEventsRetryAndViewingDay(t *testing.T) {
	a := testApp(t)
	seed(t, a, "v1", true)
	yesterday := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	payload := map[string]any{"reports": []map[string]any{{"event_id": "same-event", "day": yesterday, "video_id": "v1", "watched_ms": 5000, "played": true}}}
	for range 2 {
		object(t, request(t, a, "POST", "/api/watch", "child", payload))
	}
	var watched, plays int
	if err := a.DB.QueryRow("SELECT watched_ms,plays FROM watch_stats WHERE video_id='v1'").Scan(&watched, &plays); err != nil {
		t.Fatal(err)
	}
	if watched != 5000 || plays != 1 {
		t.Fatalf("retry counted twice: %d/%d", watched, plays)
	}
	var old int
	if err := a.DB.QueryRow("SELECT watched_ms FROM watch_days WHERE day=?", yesterday).Scan(&old); err != nil {
		t.Fatal(err)
	}
	budget := object(t, request(t, a, "GET", "/api/settings/time-limit", "child", nil))
	if old != 5000 || budget["watched_ms_today"] != float64(0) {
		t.Fatalf("late report charged today: %v", budget)
	}
}

func TestReleaseIndependentOfSourceAndDetectsCorruption(t *testing.T) {
	a := testApp(t)
	a.Config.Root = t.TempDir()
	source := filepath.Join(t.TempDir(), "app.apk")
	if err := os.WriteFile(source, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	release, err := stageAPK(a.Config, APKRelease{App: "kids", Version: "1.0.0+20", Build: 20}, source)
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(source, []byte("new build not published"), 0600)
	if _, err = stageAPK(a.Config, APKRelease{App: "kids", Version: "1.0.1+20", Build: 20}, source); err == nil {
		t.Fatal("published changed binary without increasing build number")
	}
	info := object(t, request(t, a, "GET", "/api/update/kids", "child", nil))
	if info["version"] != "1.0.0+20" {
		t.Fatal(info)
	}
	if w := request(t, a, "GET", "/"+info["url"].(string), "", nil); w.Body.String() != "original" {
		t.Fatal(w.Body.String())
	}
	if w := request(t, a, "GET", "/api/apps/kids/download?sha256=outdated", "", nil); w.Code != 409 {
		t.Fatal(w.Code)
	}
	os.WriteFile(filepath.Join(a.Config.Data, "releases", "kids", release.SHA256+".apk"), []byte("tampered"), 0600)
	if info = object(t, request(t, a, "GET", "/api/update/kids", "child", nil)); info["available"] != false {
		t.Fatal("corrupt release advertised", info)
	}
}

func TestLibraryIndexUpdatesOnEditAndCascadesOnDelete(t *testing.T) {
	a := testApp(t)
	seed(t, a, "v1", true)
	object(t, request(t, a, "PATCH", "/api/videos/v1", "parent", map[string]any{"title": "ENGLISH 数学", "description": "#math"}))
	page := object(t, request(t, a, "GET", "/api/library?search=english&tag=math", "parent", nil))
	if page["total"] != float64(1) {
		t.Fatal(page)
	}
	object(t, request(t, a, "PATCH", "/api/videos/v1", "parent", map[string]any{"title": "历史", "description": "#history"}))
	page = object(t, request(t, a, "GET", "/api/library?tag=math", "parent", nil))
	if page["total"] != float64(0) {
		t.Fatal(page)
	}
	object(t, request(t, a, "DELETE", "/api/videos/v1", "parent", nil))
	var count int
	if err := a.DB.QueryRow("SELECT COUNT(*) FROM video_catalog").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatal("stale catalog", count)
	}
}

func TestDifferentShareLinksReuseResolvedWork(t *testing.T) {
	a := testApp(t)
	seed(t, a, "existing", true)
	if _, err := a.DB.Exec("INSERT INTO video_sources VALUES('existing','douyin','12345')"); err != nil {
		t.Fatal(err)
	}
	a.ResolveVideo = func(context.Context, string) (resolvedVideo, error) {
		return resolvedVideo{ID: "12345", URLs: []string{"https://invalid.invalid/video"}}, nil
	}
	object(t, request(t, a, "POST", "/api/imports", "parent", map[string]any{"text": "https://v.douyin.com/new-share/"}))
	if _, err := a.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	var state, phase, id string
	if err := a.DB.QueryRow("SELECT state,phase,video_id FROM tasks").Scan(&state, &phase, &id); err != nil {
		t.Fatal(err)
	}
	if state != "completed" || phase != "duplicate" || id != "existing" {
		t.Fatal(state, phase, id)
	}
}
