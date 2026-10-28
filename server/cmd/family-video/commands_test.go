package main

import (
	"familyvideo/server/internal/family"
	"github.com/gofrs/flock"
	"path/filepath"
	"strings"
	"testing"
)

func TestOfflineMaintenanceRespectsServiceLock(t *testing.T) {
	config, err := family.InitConfig(family.Config{Data: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	lock := flock.New(filepath.Join(config.Data, "server.lock"))
	ok, err := lock.TryLock()
	if err != nil || !ok {
		t.Fatal(ok, err)
	}
	defer lock.Unlock()
	if err = runCommand(config, []string{"backup", "-output", filepath.Join(t.TempDir(), "backup.zip")}); err == nil || !strings.Contains(err.Error(), "停止") {
		t.Fatal("backup should refuse a live data directory", err)
	}
}
