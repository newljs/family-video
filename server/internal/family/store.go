package family

import (
	"context"
	"database/sql"
	_ "embed"
	"fmt"
	_ "modernc.org/sqlite"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

//go:embed schema.sql
var schema string

type App struct {
	Config         Config
	DB             *sql.DB
	FreeSpace      func(string) (uint64, error)
	DownloadVideo  func(context.Context, string, string) (string, error)
	ResolveVideo   func(context.Context, string) (resolvedVideo, error)
	DownloadHTTP   *http.Client
	HWEncoderProbe func(context.Context) string
	startedAt      time.Time
	usageMu        sync.Mutex
	usageAt        time.Time
	usage          []dirUsage
	usageTotal     int64
	cacheMu        sync.Mutex
	mediaMu        sync.Mutex
	taskMu         sync.Mutex
	activeTasks    map[string]context.CancelFunc
	enc            encoderCache
}

func New(c Config) (*App, error) {
	path := filepath.ToSlash(filepath.Join(c.Data, "database", "family.sqlite3"))
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	u := url.URL{Scheme: "file", Path: path}
	q := u.Query()
	q.Add("_pragma", "foreign_keys(1)")
	q.Add("_pragma", "busy_timeout(15000)")
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	var version int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		db.Close()
		return nil, err
	}
	if version > 7 {
		db.Close()
		return nil, fmt.Errorf("数据库版本 %d 高于当前支持版本，拒绝降级", version)
	}
	if err = migrate(db, c, version); err != nil {
		db.Close()
		return nil, err
	}
	app := &App{Config: c, DB: db, FreeSpace: freeSpace, activeTasks: make(map[string]context.CancelFunc), startedAt: time.Now()}
	app.ResolveVideo = app.resolveF2
	app.DownloadHTTP = newDownloadClient()
	app.DownloadVideo = app.download
	return app, nil
}

type queryer interface {
	Query(string, ...any) (*sql.Rows, error)
}

func query(db queryer, sqlText string, args ...any) ([]map[string]any, error) {
	rows, err := db.Query(sqlText, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	result := make([]map[string]any, 0)
	for rows.Next() {
		values := make([]any, len(columns))
		ptr := make([]any, len(columns))
		for i := range values {
			ptr[i] = &values[i]
		}
		if err = rows.Scan(ptr...); err != nil {
			return nil, err
		}
		item := map[string]any{}
		for i, k := range columns {
			v := values[i]
			if b, ok := v.([]byte); ok {
				v = string(b)
			}
			item[k] = v
		}
		result = append(result, item)
	}
	return result, rows.Err()
}
