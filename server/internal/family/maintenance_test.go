package family

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestBackupRestoreRoundTripAndPreservesExistingDirectory(t *testing.T) {
	a := testApp(t)
	seed(t, a, "v1", true)
	secret := filepath.Join(a.Config.Data, "private")
	os.MkdirAll(secret, 0700)
	os.WriteFile(filepath.Join(secret, "f2.yaml"), []byte("secret-cookie"), 0600)
	archive := filepath.Join(t.TempDir(), "library.zip")
	if err := CreateBackup(a, archive); err != nil {
		t.Fatal(err)
	}
	if err := VerifyBackup(archive); err != nil {
		t.Fatal(err)
	}
	contents, err := zip.OpenReader(archive)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range contents.File {
		if entry.Name == "credentials.json" || entry.Name == "private/f2.yaml" {
			t.Fatal("credential in backup")
		}
	}
	contents.Close()
	target := filepath.Join(t.TempDir(), "restored")
	if err = RestoreBackup(archive, target); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(target, "videos", "v1.mp4"))
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "0123456789abcdef" {
		t.Fatal(string(raw))
	}
	if err = RestoreBackup(archive, target); err == nil {
		t.Fatal("overwrote existing restore directory")
	}
	if _, err = os.Stat(filepath.Join(target, "videos", "v1.mp4")); err != nil {
		t.Fatal("existing library changed")
	}
	if err = CreateBackup(a, archive); err == nil {
		t.Fatal("overwrote previous backup")
	}
}

func TestBackupRejectsCorruptionAndUnsafePaths(t *testing.T) {
	a := testApp(t)
	seed(t, a, "v1", true)
	archive := filepath.Join(t.TempDir(), "library.zip")
	if err := CreateBackup(a, archive); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	// A truncated archive is rejected before creating a restore directory.
	os.WriteFile(archive, raw[:len(raw)/2], 0600)
	target := filepath.Join(t.TempDir(), "bad")
	if err = RestoreBackup(archive, target); err == nil {
		t.Fatal("accepted truncated backup")
	}
	if _, err = os.Stat(target); !os.IsNotExist(err) {
		t.Fatal("failed verification created destination")
	}
	for _, name := range []string{"../secret", "videos/../../secret", "videos\\..\\secret", "C:/file", "videos/../secret"} {
		if backupPath(name) {
			t.Fatalf("unsafe archive path allowed: %q", name)
		}
	}
}

func TestDailySnapshotAndOrphanQuarantine(t *testing.T) {
	a := testApp(t)
	seed(t, a, "v1", true)
	if err := a.dailySnapshot(); err != nil {
		t.Fatal(err)
	}
	if err := a.dailySnapshot(); err != nil {
		t.Fatal(err)
	}
	files, _ := filepath.Glob(filepath.Join(a.Config.Data, "backups", "database", "*.sqlite3"))
	if len(files) != 1 {
		t.Fatal(files)
	}
	orphan := filepath.Join(a.Config.Data, "videos", "orphan.mp4")
	os.WriteFile(orphan, []byte("abandoned"), 0600)
	old := time.Now().Add(-48 * time.Hour)
	os.Chtimes(orphan, old, old)
	candidates, err := ScanOrphans(a, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(candidates) != 1 || candidates[0].Path != "videos/orphan.mp4" {
		t.Fatal(candidates)
	}
	if _, err = os.Stat(orphan); err != nil {
		t.Fatal("scan modified files")
	}
	if _, err = ScanOrphans(a, true); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatal("orphan not moved")
	}
	moved, _ := filepath.Glob(filepath.Join(a.Config.Data, "quarantine", "*", "videos", "orphan.mp4"))
	if len(moved) != 1 {
		t.Fatal(moved)
	}
	if _, err = os.Stat(filepath.Join(a.Config.Data, "videos", "v1.mp4")); err != nil {
		t.Fatal("referenced video moved")
	}
}
