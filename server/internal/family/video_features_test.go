package family

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
