package family

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func testApp(t *testing.T) *App {
	t.Helper()
	c, e := InitConfig(Config{Data: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	a, e := New(c)
	if e != nil {
		t.Fatal(e)
	}
	a.FreeSpace = func(string) (uint64, error) { return 100 * 1024 * 1024 * 1024, nil }
	t.Cleanup(func() { a.DB.Close() })
	return a
}
func request(t *testing.T, a *App, method, path, client string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var data io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		data = bytes.NewReader(raw)
	}
	r := httptest.NewRequest(method, path, data)
	if client != "" {
		r.Header.Set("X-Family-Client", client)
	}
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	return w
}
func object(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var v map[string]any
	if e := json.Unmarshal(w.Body.Bytes(), &v); e != nil {
		t.Fatal(e)
	}
	return v
}
func list(t *testing.T, w *httptest.ResponseRecorder) []map[string]any {
	t.Helper()
	if w.Code != 200 {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var v []map[string]any
	if e := json.Unmarshal(w.Body.Bytes(), &v); e != nil {
		t.Fatal(e)
	}
	if v == nil {
		t.Fatal("expected JSON array, got null")
	}
	return v
}
func seed(t *testing.T, a *App, id string, published bool) {
	t.Helper()
	if _, e := a.DB.Exec("INSERT INTO videos(id,title,path,duration,width,height,published) VALUES(?,?,?,1,160,120,?)", id, "自然科普", id+".mp4", published); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(a.Config.Data, "videos", id+".mp4"), []byte("0123456789abcdef"), 0600); e != nil {
		t.Fatal(e)
	}
}

func TestNoReviewVisibilityAndRange(t *testing.T) {
	a := testApp(t)
	seed(t, a, "sample", false) // Legacy review flag must no longer hide this video.
	for _, client := range []string{"", "child", "parent"} {
		items := list(t, request(t, a, "GET", "/api/videos", client, nil))
		if len(items) != 1 || items[0]["published"] != float64(1) {
			t.Fatal("completed video was hidden", items)
		}
	}
	health := object(t, request(t, a, "GET", "/health", "", nil))
	if health["content_mode"] != "direct" {
		t.Fatal(health)
	}
	if request(t, a, "PATCH", "/api/videos/sample", "child", map[string]any{"title": "改名"}).Code != 403 {
		t.Fatal("child can manage")
	}
	object(t, request(t, a, "PATCH", "/api/videos/sample", "parent", map[string]any{"title": "自然", "published": false}))
	video := list(t, request(t, a, "GET", "/api/videos", "child", nil))[0]
	if video["title"] != "自然" {
		t.Fatal(video)
	}
	url := video["media_url"].(string)
	r := httptest.NewRequest("GET", url, nil)
	r.Header.Set("Range", "bytes=0-3")
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	if w.Code != 206 || w.Body.String() != "0123" {
		t.Fatalf("range %d %s", w.Code, w.Body.String())
	}
	if request(t, a, "GET", url+"x", "", nil).Code != 403 {
		t.Fatal("bad signature accepted")
	}
	for _, path := range []string{"/api/pair", "/api/pairing"} {
		if request(t, a, "POST", path, "", nil).Code != 410 {
			t.Fatal("pairing active")
		}
	}
}
func TestImportsDedupAndRetry(t *testing.T) {
	a := testApp(t)
	body := map[string]string{"text": "分享 https://v.douyin.com/abc/ 科学"}
	one := object(t, request(t, a, "POST", "/api/imports", "parent", body))
	two := object(t, request(t, a, "POST", "/api/imports", "parent", body))
	if one["id"] != two["id"] {
		t.Fatal("duplicate task")
	}
	if _, e := a.RunOnce(context.Background()); e != nil {
		t.Fatal(e)
	}
	tasks := list(t, request(t, a, "GET", "/api/tasks", "parent", nil))
	if tasks[0]["state"] != "failed" {
		t.Fatal(tasks)
	}
	object(t, request(t, a, "POST", "/api/tasks/"+one["id"].(string)+"/retry", "parent", nil))
	if request(t, a, "POST", "/api/tasks/"+one["id"].(string)+"/retry", "parent", nil).Code != 409 {
		t.Fatal("running task retried")
	}
}
func TestURLValidation(t *testing.T) {
	for _, text := range []string{"https://127.0.0.1/x", "https://douyin.com.evil.test/x", "https://user:pass@www.douyin.com/a", "https://www.douyin.com:123/x", "no url"} {
		if _, e := ExtractURL(text); e == nil {
			t.Fatal(text)
		}
	}
	if _, e := ExtractURL("分享 https://v.douyin.com/test/ 文案"); e != nil {
		t.Fatal(e)
	}
}
func TestCollectionsOrderAndVisibility(t *testing.T) {
	a := testApp(t)
	token := "child"
	seed(t, a, "one", true)
	seed(t, a, "two", false)
	object(t, request(t, a, "POST", "/api/collections", "parent", map[string]any{"title": "自然", "video_ids": []string{"two", "one", "two"}}))
	items := list(t, request(t, a, "GET", "/api/collections", token, nil))
	videos := items[0]["videos"].([]any)
	if len(videos) != 2 || videos[0].(map[string]any)["id"] != "two" {
		t.Fatal(items)
	}
	parent := list(t, request(t, a, "GET", "/api/collections", "parent", nil))
	if parent[0]["videos"].([]any)[0].(map[string]any)["id"] != "two" {
		t.Fatal("order changed")
	}
	if request(t, a, "POST", "/api/collections", "parent", map[string]any{"title": "bad", "video_ids": []string{"missing"}}).Code != 400 {
		t.Fatal("bad reference accepted")
	}
}
func uploadFile(t *testing.T, a *App, data []byte) *httptest.ResponseRecorder {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	mw.WriteField("title", "测试视频")
	part, _ := mw.CreateFormFile("file", "sample.mp4")
	part.Write(data)
	mw.Close()
	r := httptest.NewRequest("POST", "/api/uploads", &body)
	r.Header.Set("Content-Type", mw.FormDataContentType())
	r.Header.Set("X-Family-Client", "parent")
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	return w
}
func TestUploadWorkerIntegration(t *testing.T) {
	if _, e := exec.LookPath("ffmpeg"); e != nil {
		t.Skip("ffmpeg required")
	}
	a := testApp(t)
	source := filepath.Join(t.TempDir(), "test.mp4")
	if raw, e := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=green:s=160x120:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-metadata", "title=认识大自然", "-metadata", "comment=视频自带的介绍文字", source).CombinedOutput(); e != nil {
		t.Fatalf("%v %s", e, raw)
	}
	raw, _ := os.ReadFile(source)
	object(t, uploadFile(t, a, raw))
	worked, e := a.RunOnce(context.Background())
	if e != nil || !worked {
		t.Fatal(e)
	}
	tasks := list(t, request(t, a, "GET", "/api/tasks", "parent", nil))
	if tasks[0]["state"] != "completed" {
		t.Fatal(tasks)
	}
	video := list(t, request(t, a, "GET", "/api/videos", "child", nil))[0]
	if video["description"] != "视频自带的介绍文字" || video["title"] != "测试视频" {
		t.Fatal("embedded metadata or manual title lost", video)
	}
	playlist := request(t, a, "GET", video["stream_url"].(string), "", nil)
	if playlist.Code != 200 || !strings.Contains(playlist.Header().Get("Content-Type"), "mpegurl") {
		t.Fatal("HLS playlist missing", playlist.Code)
	}
	var segment string
	for _, line := range strings.Split(playlist.Body.String(), "\n") {
		if strings.HasPrefix(line, "/media/") {
			segment = line
			break
		}
	}
	response := request(t, a, "GET", segment, "", nil)
	if response.Code != 200 || response.Body.Len() == 0 || response.Body.Bytes()[0] != 0x47 {
		t.Fatal("HLS segment invalid", response.Code)
	}
	if request(t, a, "GET", strings.Replace(segment, "segment00000.ts", "segment99999.ts", 1), "", nil).Code != 403 {
		t.Fatal("unsigned segment accepted")
	}
	if request(t, a, "GET", video["thumbnail_url"].(string), "", nil).Code != 200 {
		t.Fatal("missing thumbnail")
	}
}
func TestInvalidFileAndLowStorage(t *testing.T) {
	a := testApp(t)
	object(t, uploadFile(t, a, []byte("bad")))
	a.RunOnce(context.Background())
	items := list(t, request(t, a, "GET", "/api/tasks", "parent", nil))
	if items[0]["state"] != "failed" {
		t.Fatal(items)
	}
	if len(list(t, request(t, a, "GET", "/api/videos", "parent", nil))) != 0 {
		t.Fatal("invalid published")
	}
	a.FreeSpace = func(string) (uint64, error) { return 0, nil }
	if uploadFile(t, a, []byte("x")).Code != 507 {
		t.Fatal("low storage ignored")
	}
}
func TestExistingMediaSigningAndDatabase(t *testing.T) {
	a := testApp(t)
	seed(t, a, "old-python-video", true)
	c, e := InitConfig(Config{Data: a.Config.Data})
	if e != nil {
		t.Fatal(e)
	}
	if c.SigningKey != a.Config.SigningKey {
		t.Fatal("existing media signing parameter overwritten")
	}
	other, e := New(c)
	if e != nil {
		t.Fatal(e)
	}
	defer other.DB.Close()
	items, e := query(other.DB, "SELECT id FROM videos")
	if e != nil || len(items) != 1 {
		t.Fatalf("existing data lost: %v", e)
	}
}
func TestWorkerLock(t *testing.T) {
	a := testApp(t)
	ctx, cancel := context.WithCancel(context.Background())
	wait, e := a.StartWorker(ctx)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = a.StartWorker(ctx); e == nil {
		t.Fatal("second worker acquired lock")
	}
	cancel()
	wait()
}
func TestExpiredMediaSignature(t *testing.T) {
	a := testApp(t)
	seed(t, a, "old", true)
	expires := time.Now().Unix() - 10
	path := "/media/old/video?role=admin&expires=" + strconv.FormatInt(expires, 10) + "&sig=" + a.signature("old", "video", expires, "admin")
	if request(t, a, "GET", path, "", nil).Code != 403 {
		t.Fatal("invalid expiry accepted")
	}
}
