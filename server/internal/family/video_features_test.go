package family

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestTranscodeCapsOversizedSources(t *testing.T) {
	if _, e := exec.LookPath("ffmpeg"); e != nil {
		t.Skip("ffmpeg required")
	}
	a := testApp(t)
	for _, c := range []struct{ size string; width, height int }{
		{"2048x1152", 1920, 1080},
		{"320x240", 320, 240},
	} {
		source := filepath.Join(t.TempDir(), "src.mp4")
		if raw, e := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s="+c.size+":d=1", "-c:v", "mpeg4", "-qscale:v", "5", source).CombinedOutput(); e != nil {
			t.Fatalf("%v %s", e, raw)
		}
		data, _ := os.ReadFile(source)
		object(t, uploadFile(t, a, data))
		if worked, e := a.RunOnce(context.Background()); e != nil || !worked {
			t.Fatal(worked, e)
		}
		var state string
		if e := a.DB.QueryRow("SELECT state FROM tasks ORDER BY rowid DESC LIMIT 1").Scan(&state); e != nil || state != "completed" {
			t.Fatal(state, e)
		}
		var width, height int
		if e := a.DB.QueryRow("SELECT width,height FROM videos ORDER BY rowid DESC LIMIT 1").Scan(&width, &height); e != nil {
			t.Fatal(e)
		}
		if width != c.width || height != c.height {
			t.Fatalf("%s: 输出为 %dx%d，期望 %dx%d", c.size, width, height, c.width, c.height)
		}
	}
}

func TestMetadataCaptionPlatformAndEmbeddedPriority(t *testing.T) {
	share := "8.25 09/29 a@a.aA qEH:/ :1pm 复制打开抖音极速版，看看【卡尔的AI沃茨的作品】AI做代码动画动效大片的零基础终极教程 https://v.douyin.com/3-8pa91hN60/"
	m := shareMetadata(share)
	if m.Title != "AI做代码动画动效大片的零基础终极教程" || strings.Contains(m.Description, "http") {
		t.Fatal(m)
	}
	if shareMetadata("https://v.douyin.com/abc/").Title != "" {
		t.Fatal("bare link became a title")
	}
	p := probe{}
	p.Format.Tags = map[string]string{"title": "认识海洋", "comment": "讲解潮汐的形成"}
	meta := chooseMetadata("file", false, "", videoMetadata{}, p)
	if meta.Title != "认识海洋" || meta.Description != "讲解潮汐的形成" {
		t.Fatal(meta)
	}
	meta = chooseMetadata("家长手填", true, share, videoMetadata{Title: "平台完整标题", Description: "平台详细描述"}, p)
	if meta.Title != "家长手填" || meta.Description != "平台详细描述" {
		t.Fatal(meta)
	}
	a := testApp(t)
	task := object(t, request(t, a, "POST", "/api/imports", "parent", map[string]string{"text": share}))
	if task["title"] != m.Title {
		t.Fatal(task)
	}
	var saved string
	var manual bool
	a.DB.QueryRow("SELECT share_text,title_manual FROM tasks WHERE id=?", task["id"]).Scan(&saved, &manual)
	if saved != share || manual {
		t.Fatal("caption/manual intent lost")
	}
}

func TestDeleteVideoRemovesMembershipFilesTasksAndAllowsReimport(t *testing.T) {
	a := testApp(t)
	seed(t, a, "delete-me", true)
	a.DB.Exec("UPDATE videos SET source_url=? WHERE id='delete-me'", "https://v.douyin.com/deleted/")
	a.DB.Exec("INSERT INTO tasks(id,source,title,kind,state,video_id) VALUES('old-task','https://v.douyin.com/deleted/','old','douyin','completed','delete-me')")
	object(t, request(t, a, "POST", "/api/collections", "parent", map[string]any{"title": "合集", "video_ids": []string{"delete-me"}}))
	os.WriteFile(filepath.Join(a.Config.Data, "thumbnails", "delete-me.jpg"), []byte("cover"), 0600)
	root := filepath.Join(a.Config.Data, "streams", "delete-me")
	os.MkdirAll(root, 0700)
	os.WriteFile(filepath.Join(root, "index.m3u8"), []byte("stream"), 0600)
	original := list(t, request(t, a, "GET", "/api/videos", "child", nil))[0]
	if request(t, a, "DELETE", "/api/videos/delete-me", "child", nil).Code != 403 {
		t.Fatal("child can delete")
	}
	object(t, request(t, a, "PATCH", "/api/videos/delete-me", "parent", map[string]string{"title": "更新", "description": "更新的描述"}))
	v := list(t, request(t, a, "GET", "/api/videos", "parent", nil))[0]
	if v["description"] != "更新的描述" {
		t.Fatal(v)
	}
	object(t, request(t, a, "DELETE", "/api/videos/delete-me", "parent", nil))
	if len(list(t, request(t, a, "GET", "/api/videos", "child", nil))) != 0 || len(list(t, request(t, a, "GET", "/api/collections", "child", nil))) != 0 {
		t.Fatal("deleted video visible")
	}
	if request(t, a, "GET", original["media_url"].(string), "", nil).Code != 404 {
		t.Fatal("deleted signed media still accessible")
	}
	if len(list(t, request(t, a, "GET", "/api/tasks", "parent", nil))) != 0 {
		t.Fatal("stale task remains")
	}
	for _, path := range []string{filepath.Join(a.Config.Data, "videos", "delete-me.mp4"), root, filepath.Join(a.Config.Data, "thumbnails", "delete-me.jpg")} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatal("file retained", path, err)
		}
	}
	object(t, request(t, a, "POST", "/api/imports", "parent", map[string]string{"text": "https://v.douyin.com/deleted/"}))
}

func TestDeletionRetriesBusyFileCleanup(t *testing.T) {
	a := testApp(t)
	seed(t, a, "busy", true)
	target := filepath.Join(a.Config.Data, "videos", "busy.mp4")
	os.Remove(target)
	os.Mkdir(target, 0700)
	child := filepath.Join(target, "in-use")
	os.WriteFile(child, []byte("busy"), 0600)
	object(t, request(t, a, "DELETE", "/api/videos/busy", "parent", nil))
	var n int
	a.DB.QueryRow("SELECT COUNT(*) FROM video_deletions").Scan(&n)
	if n != 1 {
		t.Fatal("cleanup job not persisted")
	}
	os.Remove(child)
	a.cleanupDeleted()
	a.DB.QueryRow("SELECT COUNT(*) FROM video_deletions").Scan(&n)
	if n != 0 {
		t.Fatal("cleanup not retried")
	}
}

func TestExistingVideoStreamBackfillFailureIsBounded(t *testing.T) {
	a := testApp(t)
	seed(t, a, "invalid", true)
	worked, err := a.backfillStream(context.Background())
	if !worked || err != nil {
		t.Fatal(worked, err)
	}
	worked, err = a.backfillStream(context.Background())
	if worked || err != nil {
		t.Fatal("failed file repeatedly repackaged", worked, err)
	}
}

func encodeArg(args []string, flag string) (string, bool) {
	for i, arg := range args {
		if arg == flag && i+1 < len(args) {
			return args[i+1], true
		}
	}
	return "", false
}

func TestEncodePlansPreferHardwareAndBoundThreads(t *testing.T) {
	a := testApp(t)
	a.HWEncoderProbe = func(context.Context) string { return "h264_videotoolbox" }
	plans := a.encodePlans(context.Background(), 1920, 1080)
	if len(plans) != 2 {
		t.Fatal(plans)
	}
	hw, sw := plans[0], plans[1]
	if hw[1] != "h264_videotoolbox" {
		t.Fatal(hw)
	}
	if bitrate, ok := encodeArg(hw, "-b:v"); !ok || bitrate != "5000k" {
		t.Fatal(hw)
	}
	if _, ok := encodeArg(hw, "-crf"); ok {
		t.Fatal("hardware plan uses crf", hw)
	}
	if threads, ok := encodeArg(sw, "-threads"); !ok || threads != strconv.Itoa(encodeThreads()) {
		t.Fatal(sw)
	}
	if sw[1] != "libx264" {
		t.Fatal(sw)
	}
	a.HWEncoderProbe = func(context.Context) string { return "" }
	b := testApp(t)
	b.HWEncoderProbe = a.HWEncoderProbe
	if plans = b.encodePlans(context.Background(), 640, 360); len(plans) != 1 || plans[0][1] != "libx264" {
		t.Fatal(plans)
	}
}

func TestVideoBitrateBySize(t *testing.T) {
	for _, c := range []struct {
		w, h int
		want string
	}{
		{1920, 1080, "5000k"},
		{1280, 720, "2500k"},
		{640, 360, "1200k"},
	} {
		if got := videoBitrate(c.w, c.h); got != c.want {
			t.Fatal(c, got)
		}
	}
}

func TestScaledSizeCapsLongEdge(t *testing.T) {
	for _, c := range []struct{ w, h, ew, eh int }{
		{3840, 2160, 1920, 1080},
		{1440, 2560, 1080, 1920},
		{1920, 1080, 1920, 1080},
		{640, 480, 640, 480},
		{4000, 4000, 1920, 1920},
	} {
		w, h := scaledSize(c.w, c.h)
		if w != c.ew || h != c.eh {
			t.Fatalf("%dx%d -> %dx%d, want %dx%d", c.w, c.h, w, h, c.ew, c.eh)
		}
	}
}

func TestEncoderCacheProbesOnceAndDisablesOnFailure(t *testing.T) {
	var c encoderCache
	calls := 0
	probe := func(context.Context) string { calls++; return "h264_test" }
	if got := c.get(context.Background(), probe); got != "h264_test" || calls != 1 {
		t.Fatal(got, calls)
	}
	if got := c.get(context.Background(), probe); got != "h264_test" || calls != 1 {
		t.Fatal("cache re-probed", got, calls)
	}
	c.disable()
	if got := c.get(context.Background(), probe); got != "" || calls != 1 {
		t.Fatal("disabled encoder still probed or used", got, calls)
	}
}

func TestEncodeVideoFallsBackFromBrokenHardwareEncoder(t *testing.T) {
	if _, e := exec.LookPath("ffmpeg"); e != nil {
		t.Skip("ffmpeg required")
	}
	a := testApp(t)
	a.HWEncoderProbe = func(context.Context) string { return "h264_does_not_exist" }
	source := filepath.Join(t.TempDir(), "src.mp4")
	if raw, e := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=320x240:d=1", "-c:v", "mpeg4", "-qscale:v", "5", source).CombinedOutput(); e != nil {
		t.Fatalf("%v %s", e, raw)
	}
	target := filepath.Join(t.TempDir(), "out.mp4")
	if e := a.encodeVideo(context.Background(), source, target, 320, 240); e != nil {
		t.Fatal(e)
	}
	p, e := inspect(context.Background(), target)
	if e != nil || len(p.Streams) == 0 || p.Streams[0].Codec != "h264" {
		t.Fatal("fallback output not h264", e)
	}
	calls := 0
	a.HWEncoderProbe = func(context.Context) string { calls++; return "h264_does_not_exist" }
	if e := a.encodeVideo(context.Background(), source, filepath.Join(t.TempDir(), "out2.mp4"), 320, 240); e != nil {
		t.Fatal(e)
	}
	if calls != 0 {
		t.Fatal("broken hardware encoder probed again after failure")
	}
}
