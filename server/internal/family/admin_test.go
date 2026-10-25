package family

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVideosListSizeAndDownload(t *testing.T) {
	a := testApp(t)
	seed(t, a, "v1", true)
	items := list(t, request(t, a, "GET", "/api/videos", "parent", nil))
	if len(items) != 1 {
		t.Fatalf("want 1 video, got %d", len(items))
	}
	if items[0]["size_bytes"] != float64(16) {
		t.Fatalf("size_bytes = %v, want 16", items[0]["size_bytes"])
	}
	url, _ := items[0]["media_url"].(string)
	if url == "" || !strings.HasPrefix(url, "/media/v1/video?") {
		t.Fatalf("media_url = %q", url)
	}
	w := request(t, a, "GET", url+"&dl=1", "", nil)
	if w.Code != 200 {
		t.Fatalf("download status %d: %s", w.Code, w.Body.String())
	}
	if disp := w.Header().Get("Content-Disposition"); !strings.Contains(disp, "attachment") || !strings.Contains(disp, ".mp4") {
		t.Fatalf("Content-Disposition = %q", disp)
	}
	// 不带 dl 参数时保持内联播放行为
	w = request(t, a, "GET", url, "", nil)
	if w.Code != 200 || w.Header().Get("Content-Disposition") != "" {
		t.Fatalf("inline playback broken: %d %q", w.Code, w.Header().Get("Content-Disposition"))
	}
}

func TestAppsListAndDownload(t *testing.T) {
	a := testApp(t)
	root := t.TempDir()
	a.Config.Root = root
	apkDir := filepath.Join(root, "apps", "kids_app", "build", "app", "outputs", "flutter-apk")
	if err := os.MkdirAll(apkDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(apkDir, "app-debug.apk"), []byte("fake-apk-bytes"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "apps", "kids_app", "pubspec.yaml"), []byte("name: kids_app\nversion: 0.8.1+12\n"), 0644); err != nil {
		t.Fatal(err)
	}

	apps := list(t, request(t, a, "GET", "/api/apps", "parent", nil))
	if len(apps) != 2 {
		t.Fatalf("want 2 apps, got %d", len(apps))
	}
	byName := map[string]map[string]any{}
	for _, app := range apps {
		byName[app["app"].(string)] = app
	}
	if byName["parent"]["available"] != false {
		t.Fatalf("parent should be unavailable, got %v", byName["parent"]["available"])
	}
	kids := byName["kids"]
	if kids["available"] != true || kids["version"] != "0.8.1+12" || kids["size_bytes"] != float64(14) {
		t.Fatalf("kids app meta wrong: %v", kids)
	}

	w := request(t, a, "GET", "/api/apps/kids/download", "", nil)
	if w.Code != 200 {
		t.Fatalf("download status %d: %s", w.Code, w.Body.String())
	}
	if disp := w.Header().Get("Content-Disposition"); !strings.Contains(disp, "family-video-kids-0.8.1+12.apk") {
		t.Fatalf("Content-Disposition = %q", disp)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/vnd.android.package-archive" {
		t.Fatalf("Content-Type = %q", ct)
	}
	if w.Body.String() != "fake-apk-bytes" {
		t.Fatal("download body mismatch")
	}

	if w := request(t, a, "GET", "/api/apps/parent/download", "", nil); w.Code != 404 {
		t.Fatalf("unbuilt apk should 404, got %d", w.Code)
	}
	if w := request(t, a, "GET", "/api/apps/bogus/download", "", nil); w.Code != 404 {
		t.Fatalf("unknown app should 404, got %d", w.Code)
	}
}

func TestUpdateCheck(t *testing.T) {
	a := testApp(t)
	root := t.TempDir()
	a.Config.Root = root
	apkDir := filepath.Join(root, "apps", "parent_app", "build", "app", "outputs", "flutter-apk")
	if err := os.MkdirAll(apkDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(apkDir, "app-debug.apk"), []byte("apk"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "apps", "parent_app", "pubspec.yaml"), []byte("name: parent_app\nversion: 0.7.1+10\n"), 0644); err != nil {
		t.Fatal(err)
	}

	// 已构建：返回版本与下载地址，儿童客户端也可访问。
	info := object(t, request(t, a, "GET", "/api/update/parent", "child", nil))
	if info["available"] != true || info["version"] != "0.7.1+10" || info["url"] != "api/apps/parent/download" {
		t.Fatalf("update info wrong: %v", info)
	}
	// 未构建：available=false 而不是报错。
	info = object(t, request(t, a, "GET", "/api/update/kids", "child", nil))
	if info["available"] != false {
		t.Fatalf("unbuilt app should report available=false: %v", info)
	}
	if w := request(t, a, "GET", "/api/update/bogus", "child", nil); w.Code != 404 {
		t.Fatalf("unknown app should 404, got %d", w.Code)
	}
	// 安装包下载对 child 角色开放（儿童端自更新）。
	if w := request(t, a, "GET", "/api/apps/parent/download", "child", nil); w.Code != 200 {
		t.Fatalf("child client apk download should work, got %d", w.Code)
	}
}
