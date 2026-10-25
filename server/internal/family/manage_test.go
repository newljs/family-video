package family

import (
	"context"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestUpdateCollectionAtomicOrderRemovalAndPermissions(t *testing.T) {
	a := testApp(t)
	token := "child"
	seed(t, a, "one", true)
	seed(t, a, "two", true)
	seed(t, a, "three", false)
	initial := object(t, request(t, a, "POST", "/api/collections", "parent", map[string]any{"title": "原合集", "video_ids": []string{"one", "two"}}))
	path := "/api/collections/" + initial["id"].(string)
	edit := map[string]any{"title": "科学", "video_ids": []string{"two", "three", "one"}}
	if request(t, a, "PUT", path, token, edit).Code != 403 {
		t.Fatal("child changed collection")
	}
	object(t, request(t, a, "PUT", path, "parent", edit))
	items := list(t, request(t, a, "GET", "/api/collections", "parent", nil))
	videos := items[0]["videos"].([]any)
	if items[0]["title"] != "科学" || videos[0].(map[string]any)["id"] != "two" || videos[2].(map[string]any)["id"] != "one" {
		t.Fatal(items)
	}
	if request(t, a, "PUT", path, "parent", map[string]any{"title": "不应保存", "video_ids": []string{"missing"}}).Code != 400 {
		t.Fatal("invalid video accepted")
	}
	after := list(t, request(t, a, "GET", "/api/collections", "parent", nil))
	if after[0]["title"] != "科学" || len(after[0]["videos"].([]any)) != 3 {
		t.Fatal("failed update was not rolled back")
	}
	object(t, request(t, a, "PUT", path, "parent", map[string]any{"title": "空合集", "video_ids": []string{}}))
	if len(list(t, request(t, a, "GET", "/api/collections", token, nil))) != 0 {
		t.Fatal("empty collection visible")
	}
	if request(t, a, "DELETE", path, token, nil).Code != 403 {
		t.Fatal("child deleted collection")
	}
	object(t, request(t, a, "DELETE", path, "parent", nil))
	if len(list(t, request(t, a, "GET", "/api/collections", "parent", nil))) != 0 {
		t.Fatal("collection not deleted")
	}
	if len(list(t, request(t, a, "GET", "/api/videos", "parent", nil))) != 3 {
		t.Fatal("collection deletion removed videos")
	}
	if _, err := os.Stat(filepath.Join(a.Config.Data, "videos", "one.mp4")); err != nil {
		t.Fatal("source file removed")
	}
	if request(t, a, "PUT", path, "parent", edit).Code != 404 {
		t.Fatal("missing collection update")
	}
}

func TestCancelQueuedFailedAndCompletedTasks(t *testing.T) {
	a := testApp(t)
	token := "child"
	task := object(t, uploadFile(t, a, []byte("invalid video")))
	id := task["id"].(string)
	path := "/api/tasks/" + id + "/cancel"
	if request(t, a, "POST", path, token, nil).Code != 403 {
		t.Fatal("child cancelled task")
	}
	object(t, request(t, a, "POST", path, "parent", nil))
	object(t, request(t, a, "POST", path, "parent", nil))
	if _, err := os.Stat(filepath.Join(a.Config.Data, "temp", id+".mp4")); !os.IsNotExist(err) {
		t.Fatal("cancelled source retained")
	}
	worked, err := a.RunOnce(context.Background())
	if err != nil || worked {
		t.Fatal("cancelled task was executed", err)
	}
	if request(t, a, "POST", "/api/tasks/missing/cancel", "parent", nil).Code != 404 {
		t.Fatal("missing task")
	}
	if _, err = a.DB.Exec("INSERT INTO tasks(id,source,title,kind,state) VALUES('finished','done','done','upload','completed')"); err != nil {
		t.Fatal(err)
	}
	if request(t, a, "POST", "/api/tasks/finished/cancel", "parent", nil).Code != 409 {
		t.Fatal("completed task cancelled")
	}
	object(t, request(t, a, "POST", "/api/imports", "parent", map[string]string{"text": "https://v.douyin.com/reimport/"}))
	if _, err = a.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	tasks := list(t, request(t, a, "GET", "/api/tasks", "parent", nil))
	var failed string
	for _, task := range tasks {
		if task["state"] == "failed" {
			failed = task["id"].(string)
		}
	}
	if failed == "" {
		t.Fatal("missing failed task")
	}
	object(t, request(t, a, "POST", "/api/tasks/"+failed+"/cancel", "parent", nil))
	next := object(t, request(t, a, "POST", "/api/imports", "parent", map[string]string{"text": "https://v.douyin.com/reimport/"}))
	if next["id"] == failed {
		t.Fatal("cancelled task blocked reimport")
	}
}

func TestCancelRunningDownloadStopsProviderAndPreservesState(t *testing.T) {
	a := testApp(t)
	task := object(t, request(t, a, "POST", "/api/imports", "parent", map[string]string{"text": "https://v.douyin.com/blocking/"}))
	id := task["id"].(string)
	entered := make(chan struct{})
	exited := make(chan struct{})
	a.DownloadVideo = func(ctx context.Context, source, folder string) (string, error) {
		os.WriteFile(filepath.Join(folder, "partial.mp4"), []byte("partial"), 0600)
		close(entered)
		<-ctx.Done()
		close(exited)
		return "", ctx.Err()
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := a.RunOnce(ctx); done <- err }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("provider did not start")
	}
	object(t, request(t, a, "POST", "/api/tasks/"+id+"/cancel", "parent", nil))
	select {
	case <-exited:
	case <-time.After(3 * time.Second):
		t.Fatal("provider was not stopped")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("worker did not finish")
	}
	items := list(t, request(t, a, "GET", "/api/tasks", "parent", nil))
	if items[0]["state"] != "cancelled" {
		t.Fatal(items)
	}
	if len(list(t, request(t, a, "GET", "/api/videos", "parent", nil))) != 0 {
		t.Fatal("cancelled video was inserted")
	}
	if _, err := os.Stat(filepath.Join(a.Config.Data, "temp", id)); !os.IsNotExist(err) {
		t.Fatal(fmt.Sprint("partial files retained: ", err))
	}
}

func TestConcurrentImportAndCancellation(t *testing.T) {
	a := testApp(t)
	for i := 0; i < 20; i++ {
		body := map[string]string{"text": fmt.Sprintf("https://v.douyin.com/concurrent-%d/", i)}
		first := object(t, request(t, a, "POST", "/api/imports", "parent", body))
		start := make(chan struct{})
		results := make(chan *httptest.ResponseRecorder, 2)
		go func() { <-start; results <- request(t, a, "POST", "/api/imports", "parent", body) }()
		go func() {
			<-start
			results <- request(t, a, "POST", "/api/tasks/"+first["id"].(string)+"/cancel", "parent", nil)
		}()
		close(start)
		for n := 0; n < 2; n++ {
			select {
			case result := <-results:
				if result.Code != 200 {
					t.Fatalf("concurrent operation %d %s", result.Code, result.Body.String())
				}
			case <-time.After(3 * time.Second):
				t.Fatal("transaction deadlock")
			}
		}
	}
}
