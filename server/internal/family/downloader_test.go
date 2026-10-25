package family

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func init() {
	mode := os.Getenv("FAMILY_TEST_RESOLVER")
	if mode == "" {
		return
	}
	if mode == "bad_json" {
		os.Stdout.WriteString("not json")
		os.Exit(0)
	}
	if expected := os.Getenv("FAMILY_TEST_CONFIG"); expected != "" && !strings.Contains(strings.Join(os.Args, " "), expected) {
		os.Exit(4)
	}
	if mode == "denied" {
		os.Stdout.WriteString(`{"error":{"code":"login_required","message":"cookie=must-not-leak"}}`)
		os.Exit(1)
	}
	if mode == "unknown" {
		os.Stdout.WriteString(`{"error":{"code":"upstream-secret","message":"cookie=must-not-leak"}}`)
		os.Exit(1)
	}
	os.Stdout.WriteString(`{"id":"123","title":"test","urls":["https://video.example.test/file"],"headers":{"User-Agent":"test"}}`)
	os.Exit(0)
}
func TestResolverProtocolAndPrivateConfig(t *testing.T) {
	for _, mode := range []string{"success", "denied", "unknown", "bad_json"} {
		t.Run(mode, func(t *testing.T) {
			a := testApp(t)
			a.Config.Root = t.TempDir()
			p := filepath.Join(a.Config.Root, "server", "downloader", "resolve.py")
			os.MkdirAll(filepath.Dir(p), 0700)
			os.WriteFile(p, []byte("# fake resolver"), 0600)
			a.Config.ResolverPython, _ = os.Executable()
			config := filepath.Join(a.Config.Data, "private", "f2.yaml")
			os.MkdirAll(filepath.Dir(config), 0700)
			os.WriteFile(config, []byte("{}"), 0600)
			t.Setenv("FAMILY_TEST_RESOLVER", mode)
			t.Setenv("FAMILY_TEST_CONFIG", config)
			video, err := a.resolveF2(context.Background(), "https://v.douyin.com/example/")
			if mode == "success" {
				if err != nil || video.ID != "123" {
					t.Fatal(video, err)
				}
				return
			}
			if err == nil || strings.Contains(err.Error(), "must-not-leak") {
				t.Fatal("unsafe resolver error", err)
			}
		})
	}
}
func TestDownloadCandidatesRefreshAndPartialCleanup(t *testing.T) {
	a := testApp(t)
	var hits int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Header.Get("Cookie") != "" {
			t.Error("account cookie forwarded to CDN")
		}
		if r.URL.Path != "/good" {
			w.WriteHeader(403)
			return
		}
		w.Header().Set("Content-Type", "video/mp4")
		io.WriteString(w, "a complete video body")
	}))
	defer server.Close()
	a.DownloadHTTP = server.Client()
	calls := 0
	a.ResolveVideo = func(context.Context, string) (resolvedVideo, error) {
		calls++
		urls := []string{server.URL + "/expired"}
		if calls == 2 {
			urls = []string{server.URL + "/denied", server.URL + "/good"}
		}
		return resolvedVideo{ID: "123", URLs: urls, Headers: map[string]string{"Cookie": "private-value", "User-Agent": "test"}}, nil
	}
	path, err := a.download(context.Background(), "https://v.douyin.com/example/", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if string(raw) != "a complete video body" || calls != 2 || hits != 3 {
		t.Fatal(calls, hits, string(raw))
	}
	if _, err := os.Stat(path + ".part"); !os.IsNotExist(err) {
		t.Fatal("partial file retained")
	}
}
func TestTransferRejectsTruncationRateLimitAndHTML(t *testing.T) {
	a := testApp(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/rate":
			w.Header().Set("Retry-After", "90")
			w.WriteHeader(429)
		case "/html":
			w.Header().Set("Content-Type", "text/html")
			io.WriteString(w, "captcha")
		default:
			w.Header().Set("Content-Type", "video/mp4")
			w.Header().Set("Content-Length", "200")
			io.WriteString(w, "short")
		}
	}))
	defer server.Close()
	a.DownloadHTTP = server.Client()
	for _, test := range []struct{ path, code string }{{"/short", "media_incomplete"}, {"/rate", "rate_limited"}, {"/html", "invalid_media"}} {
		target := filepath.Join(t.TempDir(), "video.part")
		err := a.transfer(context.Background(), server.URL+test.path, nil, target)
		var de *downloadError
		if !errors.As(err, &de) || de.Code != test.code {
			t.Fatal(test, err)
		}
		if test.code == "rate_limited" && de.RetryAfter != 90*time.Second {
			t.Fatal("Retry-After lost")
		}
		if _, e := os.Stat(target); !os.IsNotExist(e) {
			t.Fatal("failed transfer retained a partial file")
		}
	}
}
func TestSourceCacheIntegrityExpiryAndCancellation(t *testing.T) {
	a := testApp(t)
	source := "https://v.douyin.com/cached/"
	raw := filepath.Join(t.TempDir(), "raw.mp4")
	os.WriteFile(raw, []byte("original body"), 0600)
	a.cacheSource(context.Background(), source, raw)
	a.ResolveVideo = func(context.Context, string) (resolvedVideo, error) {
		t.Fatal("cache unexpectedly called resolver")
		return resolvedVideo{}, nil
	}
	path, err := a.download(context.Background(), source, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "original body" {
		t.Fatal("cache wrong content")
	}
	cacheRoot := filepath.Join(a.Config.Data, "download-cache")
	os.WriteFile(filepath.Join(cacheRoot, sourceKey(source)+".mp4"), []byte("corrupt"), 0600)
	if _, ok := a.cachedSource(context.Background(), source, t.TempDir()); ok {
		t.Fatal("corrupt cached source accepted")
	}
	a.cacheSource(context.Background(), source, raw)
	manifest := filepath.Join(cacheRoot, sourceKey(source)+".json")
	b, _ := os.ReadFile(manifest)
	var m sourceManifest
	json.Unmarshal(b, &m)
	m.Created = time.Now().Add(-25 * time.Hour).Unix()
	b, _ = json.Marshal(m)
	os.WriteFile(manifest, b, 0600)
	if _, ok := a.cachedSource(context.Background(), source, t.TempDir()); ok {
		t.Fatal("expired cache accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = a.download(ctx, source, t.TempDir()); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
func TestRetryScheduleLimitAndManualReset(t *testing.T) {
	a := testApp(t)
	task := object(t, request(t, a, "POST", "/api/imports", "parent", map[string]string{"text": "https://v.douyin.com/retry/"}))
	id := task["id"].(string)
	a.DownloadVideo = func(context.Context, string, string) (string, error) {
		return "", derror("media_denied", "视频源拒绝访问", true)
	}
	for n := 1; n <= 3; n++ {
		worked, err := a.RunOnce(context.Background())
		if err != nil || !worked {
			t.Fatal(worked, err)
		}
		var state, phase, code string
		var retries int
		var next int64
		a.DB.QueryRow("SELECT state,phase,error_code,auto_retries,next_attempt_at FROM tasks WHERE id=?", id).Scan(&state, &phase, &code, &retries, &next)
		if n < 3 {
			if state != "queued" || phase != "retry_wait" || next <= time.Now().Unix() || retries != n {
				t.Fatal(state, phase, retries, next)
			}
			worked, err = a.RunOnce(context.Background())
			if err != nil || worked {
				t.Fatal("future retry ran early")
			}
			a.DB.Exec("UPDATE tasks SET next_attempt_at=0 WHERE id=?", id)
		} else if state != "failed" || retries != 2 || code != "media_denied" {
			t.Fatal(state, retries, code)
		}
	}
	object(t, request(t, a, "POST", "/api/tasks/"+id+"/retry", "parent", nil))
	var retries int
	var next int64
	a.DB.QueryRow("SELECT auto_retries,next_attempt_at FROM tasks WHERE id=?", id).Scan(&retries, &next)
	if retries != 0 || next != 0 {
		t.Fatal("manual retry did not reset budget")
	}
	a.DownloadVideo = func(context.Context, string, string) (string, error) {
		return "", derror("login_required", "需要更新登录配置", false)
	}
	a.RunOnce(context.Background())
	tasks := list(t, request(t, a, "GET", "/api/tasks", "parent", nil))
	if tasks[0]["state"] != "failed" {
		t.Fatal("login failure retried indefinitely")
	}
}
func TestDownloadNetworkAddressGuard(t *testing.T) {
	for _, s := range []string{"127.0.0.1", "192.168.1.1", "10.0.0.1", "169.254.169.254", "100.64.0.1", "::1", "fd00::1", "::ffff:127.0.0.1"} {
		if publicAddress(netip.MustParseAddr(s)) {
			t.Fatal("private address allowed", s)
		}
	}
	for _, s := range []string{"1.1.1.1", "2606:4700:4700::1111"} {
		if !publicAddress(netip.MustParseAddr(s)) {
			t.Fatal("public address blocked", s)
		}
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("LAN endpoint reached") }))
	defer server.Close()
	c := newDownloadClient()
	if _, err := c.Get(server.URL); err == nil {
		t.Fatal("LAN transfer accepted")
	}
}
