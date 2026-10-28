package family

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTVPublishedAPKIsIndependentAndIntegrityChecked(t *testing.T) {
	a := testApp(t)
	source := filepath.Join(t.TempDir(), "tv.apk")
	if err := os.WriteFile(source, []byte("tv-test-build"), 0600); err != nil {
		t.Fatal(err)
	}
	if !validClientApp("tv") || validClientApp("../tv") {
		t.Fatal("invalid TV client registration")
	}
	release, err := stageAPK(a.Config, APKRelease{App: "tv", Package: "cn.familyvideo.tv_app", Version: "0.1.0+1", Build: 1}, source)
	if err != nil {
		t.Fatal(err)
	}
	info := object(t, request(t, a, "GET", "/api/update/tv", "child", nil))
	if info["available"] != true || info["version"] != "0.1.0+1" {
		t.Fatal(info)
	}
	if w := request(t, a, "GET", "/"+info["url"].(string), "child", nil); w.Code != 200 || w.Body.String() != "tv-test-build" {
		t.Fatalf("TV download: %d %s", w.Code, w.Body.String())
	}
	if object(t, request(t, a, "GET", "/api/update/kids", "child", nil))["available"] != false {
		t.Fatal("TV APK leaked into kids publication")
	}
	if err := os.WriteFile(filepath.Join(a.Config.Data, "releases", "tv", release.SHA256+".apk"), []byte("corrupt"), 0600); err != nil {
		t.Fatal(err)
	}
	if w := request(t, a, "GET", "/api/apps/tv/download", "child", nil); w.Code != 404 {
		t.Fatalf("corrupt TV APK exposed: %d", w.Code)
	}
}
