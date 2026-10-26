package family

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMigrationMakesLegacyVideosVisibleAndBacksUp(t *testing.T) {
	c, err := InitConfig(Config{Data: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(c.Data, "database", "family.sqlite3")
	db, err := sql.Open("sqlite", p)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE videos(id TEXT PRIMARY KEY,title TEXT NOT NULL,source_url TEXT,published INTEGER NOT NULL DEFAULT 0,path TEXT NOT NULL,duration REAL NOT NULL,width INTEGER NOT NULL,height INTEGER NOT NULL,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
 CREATE TABLE tasks(id TEXT PRIMARY KEY,source TEXT NOT NULL,title TEXT NOT NULL,kind TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'queued',error TEXT,video_id TEXT,attempts INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
 INSERT INTO videos VALUES('old','legacy',NULL,0,'old.mp4',1,160,120,CURRENT_TIMESTAMP);PRAGMA user_version=1;`)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	a, err := New(c)
	if err != nil {
		t.Fatal(err)
	}
	defer a.DB.Close()
	var version, published int
	a.DB.QueryRow("PRAGMA user_version").Scan(&version)
	a.DB.QueryRow("SELECT published FROM videos WHERE id='old'").Scan(&published)
	if version != 5 || published != 1 {
		t.Fatal(version, published)
	}
	backups, _ := filepath.Glob(filepath.Join(c.Data, "database", "before-v3-*.sqlite3"))
	if len(backups) != 1 {
		t.Fatal(backups)
	}
	backup, err := sql.Open("sqlite", backups[0])
	if err != nil {
		t.Fatal(err)
	}
	defer backup.Close()
	backup.QueryRow("SELECT published FROM videos WHERE id='old'").Scan(&published)
	if published != 0 {
		t.Fatal("backup was not pre-migration")
	}
	other, err := New(c)
	if err != nil {
		t.Fatal(err)
	}
	other.DB.Close()
	again, _ := filepath.Glob(filepath.Join(c.Data, "database", "before-v3-*.sqlite3"))
	if len(again) != 1 {
		t.Fatal("migration repeated")
	}
	os.WriteFile(filepath.Join(c.Data, "videos", "old.mp4"), []byte("old data"), 0600)
	items := list(t, request(t, a, "GET", "/api/videos", "child", nil))
	if len(items) != 1 {
		t.Fatal(items)
	}
	if request(t, a, "GET", items[0]["media_url"].(string), "", nil).Code != 200 {
		t.Fatal("legacy media hidden")
	}
}

func TestMigrationFromV2PreservesManualTitlesAndSchedulesStreaming(t *testing.T) {
	c, err := InitConfig(Config{Data: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(c.Data, "database", "family.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	old := strings.Replace(schema, " description TEXT NOT NULL DEFAULT '', stream_state TEXT NOT NULL DEFAULT 'pending',", "", 1)
	old = strings.Replace(old, " share_text TEXT NOT NULL DEFAULT '', title_manual INTEGER NOT NULL DEFAULT 0,", "", 1)
	if _, err = db.Exec(old + ";INSERT INTO videos(id,title,path,duration,width,height) VALUES('old','自定义标题','old.mp4',1,160,120);INSERT INTO tasks(id,source,title,kind) VALUES('t','link','家长标题','douyin');PRAGMA user_version=2;"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	app, err := New(c)
	if err != nil {
		t.Fatal(err)
	}
	defer app.DB.Close()
	var state, description string
	var manual bool
	if err = app.DB.QueryRow("SELECT stream_state,description FROM videos WHERE id='old'").Scan(&state, &description); err != nil {
		t.Fatal(err)
	}
	app.DB.QueryRow("SELECT title_manual FROM tasks WHERE id='t'").Scan(&manual)
	if state != "pending" || description != "" || !manual {
		t.Fatal(state, description, manual)
	}
}
