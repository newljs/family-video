package family

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestFailedDouyinTaskRemovesDownloadTemp(t *testing.T) {
	a := testApp(t)
	a.ResolveVideo = func(context.Context, string) (resolvedVideo, error) {
		return resolvedVideo{}, derror("resolve_failed", "暂时无法解析作品", false)
	}
	id := ID()
	if _, err := a.DB.Exec("INSERT INTO tasks(id,source,title,kind,state) VALUES(?,?,?,'douyin','queued')", id, "https://v.douyin.com/fail/", "t"); err != nil {
		t.Fatal(err)
	}
	worked, err := a.RunOnce(context.Background())
	if err != nil || !worked {
		t.Fatalf("RunOnce: worked=%v err=%v", worked, err)
	}
	var state string
	if err = a.DB.QueryRow("SELECT state FROM tasks WHERE id=?", id).Scan(&state); err != nil {
		t.Fatal(err)
	}
	if state != "failed" {
		t.Fatalf("state = %q", state)
	}
	if _, err = os.Stat(filepath.Join(a.Config.Data, "temp", id)); !os.IsNotExist(err) {
		t.Fatalf("failed download temp retained: %v", err)
	}
}
