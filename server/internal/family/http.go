package family

import (
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

type apiError struct {
	code    int
	message string
}

func (e apiError) Error() string      { return e.message }
func fail(code int, msg string) error { return apiError{code, msg} }
func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

type handler func(http.ResponseWriter, *http.Request, string) error

func (a *App) route(mux *http.ServeMux, pattern, access string, h handler) {
	mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
		// Client kind is a public display hint, not a credential. This server
		// deliberately permits management from the trusted home LAN.
		role := "child"
		client := r.Header.Get("X-Family-Client")
		var err error
		if client == "parent" || (access == "admin" && client != "child") {
			role = "admin"
		}
		if access == "admin" && client == "child" {
			err = fail(403, "请在家长端管理内容")
		}
		if err == nil {
			err = h(w, r, role)
		}
		if err != nil {
			var e apiError
			if errors.As(err, &e) {
				reply(w, e.code, map[string]any{"detail": e.message})
			} else {
				log.Printf("%s %s: %v", r.Method, r.URL.Path, err)
				reply(w, 500, map[string]any{"detail": "服务器处理失败"})
			}
		}
	})
}
func decode(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 1024*1024))
	if err := dec.Decode(v); err != nil {
		return fail(400, "请求格式错误")
	}
	var extra any
	if dec.Decode(&extra) != io.EOF {
		return fail(400, "请求只能包含一个 JSON 对象")
	}
	return nil
}
func valid(s string, max int) bool {
	n := utf8.RuneCountInString(strings.TrimSpace(s))
	return n > 0 && n <= max
}
func (a *App) signature(id, res string, expires int64, role string) string {
	mac := hmac.New(sha256.New, []byte(a.Config.SigningKey))
	fmt.Fprintf(mac, "%s:%s:%d:%s", id, res, expires, role)
	return hex.EncodeToString(mac.Sum(nil))
}
func (a *App) present(v map[string]any, role string) map[string]any {
	delete(v, "path")
	v["published"] = int64(1) // compatibility only; there is no review state
	expires := time.Now().Unix() + 86400
	for field, res := range map[string]string{"media_url": "video", "thumbnail_url": "thumbnail"} {
		q := url.Values{"expires": {strconv.FormatInt(expires, 10)}, "role": {role}, "sig": {a.signature(v["id"].(string), res, expires, role)}}
		v[field] = "/media/" + v["id"].(string) + "/" + res + "?" + q.Encode()
	}
	if v["stream_state"] == "ready" {
		v["stream_url"] = a.streamURL(v["id"].(string), "stream.m3u8", role, expires)
	}
	return v
}
func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()
	a.route(mux, "GET /health", "public", func(w http.ResponseWriter, r *http.Request, _ string) error {
		reply(w, 200, map[string]string{"status": "ok", "version": "0.7.0", "backend": "go", "access_mode": "open_lan", "content_mode": "direct", "library_mode": "managed", "streaming_mode": "hls"})
		return nil
	})
	a.route(mux, "GET /api/me", "child", func(w http.ResponseWriter, r *http.Request, role string) error {
		if role != "admin" {
			role = "child"
		}
		reply(w, 200, map[string]string{"role": role, "access_mode": "open_lan", "content_mode": "direct", "library_mode": "managed", "streaming_mode": "hls"})
		return nil
	})
	for _, pattern := range []string{"POST /api/pairing", "POST /api/pair", "GET /api/devices", "DELETE /api/devices/{id}"} {
		a.route(mux, pattern, "public", func(w http.ResponseWriter, r *http.Request, _ string) error {
			return fail(410, "已取消设备配对，请更新客户端后直接填写服务器地址连接")
		})
	}
	a.route(mux, "POST /api/imports", "admin", a.importLink)
	a.route(mux, "POST /api/uploads", "admin", a.upload)
	a.route(mux, "GET /api/tasks", "admin", func(w http.ResponseWriter, r *http.Request, _ string) error {
		items, err := query(a.DB, "SELECT id,title,kind,state,phase,downloaded_bytes,total_bytes,error,error_code,video_id,attempts,auto_retries,next_attempt_at FROM tasks ORDER BY created_at DESC,rowid DESC LIMIT 200")
		if err == nil {
			reply(w, 200, items)
		}
		return err
	})
	a.route(mux, "POST /api/tasks/{id}/retry", "admin", a.retry)
	a.route(mux, "POST /api/tasks/{id}/cancel", "admin", a.cancelImport)
	a.route(mux, "GET /api/videos", "child", func(w http.ResponseWriter, r *http.Request, role string) error {
		items, err := query(a.DB, "SELECT * FROM videos ORDER BY created_at DESC,rowid DESC")
		if err == nil {
			for _, v := range items {
				a.present(v, role)
			}
			reply(w, 200, items)
		}
		return err
	})
	a.route(mux, "PATCH /api/videos/{id}", "admin", a.editVideo)
	a.route(mux, "DELETE /api/videos/{id}", "admin", a.deleteVideo)
	a.route(mux, "GET /api/collections", "child", a.collections)
	a.route(mux, "POST /api/collections", "admin", a.createCollection)
	a.route(mux, "PUT /api/collections/{id}", "admin", a.updateCollection)
	a.route(mux, "DELETE /api/collections/{id}", "admin", a.deleteCollection)
	a.route(mux, "GET /media/{id}/{resource}", "public", a.media)
	return mux
}

var shareURL = regexp.MustCompile(`https?://[^\s<>"，。；！]+`)

func ExtractURL(text string) (string, error) {
	text = strings.ReplaceAll(text, `\:`, ":")
	raw := strings.TrimRight(shareURL.FindString(text), ".,;!)/")
	u, err := url.Parse(raw)
	if err != nil || u == nil {
		return "", fail(400, "分享内容中没有有效链接")
	}
	host := u.Hostname()
	if (host != "douyin.com" && host != "www.douyin.com" && host != "v.douyin.com") || u.User != nil || (u.Port() != "" && u.Port() != "80" && u.Port() != "443") {
		return "", fail(400, "目前只接收抖音分享链接")
	}
	return raw, nil
}
func (a *App) importLink(w http.ResponseWriter, r *http.Request, _ string) error {
	var b struct{ Text, Title string }
	if err := decode(r, &b); err != nil {
		return err
	}
	manual := !automaticTitle(b.Title)
	if !manual {
		b.Title = shareMetadata(b.Text).Title
		if b.Title == "" {
			b.Title = "新收集的视频"
		}
	}
	if !valid(b.Text, 10000) || !valid(b.Title, 200) {
		return fail(400, "分享内容或标题长度无效")
	}
	source, err := ExtractURL(b.Text)
	if err != nil {
		return err
	}
	id := ID()
	tx, err := a.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.Exec("INSERT OR IGNORE INTO tasks(id,source,title,kind,share_text,title_manual) VALUES(?,?,?,'douyin',?,?)", id, source, b.Title, b.Text, manual)
	if err != nil {
		return err
	}
	items, err := query(tx, "SELECT id,title,kind,state,phase,downloaded_bytes,total_bytes,error,error_code,video_id,attempts,auto_retries,next_attempt_at FROM tasks WHERE source=? AND state NOT IN ('failed','cancelled')", source)
	if err != nil {
		return err
	}
	if len(items) == 0 {
		return fail(409, "任务状态已变化，请重试")
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	reply(w, 200, items[0])
	return nil
}
func (a *App) upload(w http.ResponseWriter, r *http.Request, _ string) error {
	free, err := a.FreeSpace(a.Config.Data)
	if err != nil {
		return err
	}
	if free < 3*1024*1024*1024 {
		return fail(507, "磁盘剩余空间不足 3GB")
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2*1024*1024*1024+1024*1024)
	reader, err := r.MultipartReader()
	if err != nil {
		return fail(400, "需要 multipart 文件上传")
	}
	id := ID()
	path := filepath.Join(a.Config.Data, "temp", id+".mp4")
	success := false
	defer func() {
		if !success {
			os.Remove(path)
		}
	}()
	title := "本地视频"
	manual := false
	filename := ""
	size := int64(0)
	found := false
	for {
		part, e := reader.NextPart()
		if e == io.EOF {
			break
		}
		if e != nil {
			return fail(413, "上传失败或文件超过 2GB")
		}
		switch part.FormName() {
		case "title":
			data, e := io.ReadAll(io.LimitReader(part, 2048))
			if e != nil {
				return e
			}
			title = string(data)
			manual = !automaticTitle(title)
			if title == "" {
				title = "本地视频"
			}
		case "file":
			filename = clipped(strings.TrimSuffix(filepath.Base(part.FileName()), filepath.Ext(part.FileName())), 200)
			if found {
				return fail(400, "一次只能上传一个视频")
			}
			found = true
			f, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if e != nil {
				return e
			}
			size, e = io.Copy(f, io.LimitReader(part, 2*1024*1024*1024+1))
			closeErr := f.Close()
			if e != nil {
				return fail(400, "视频上传中断")
			}
			if closeErr != nil {
				return closeErr
			}
			if size > 2*1024*1024*1024 {
				return fail(413, "单个文件上限 2GB")
			}
		}
		part.Close()
	}
	if !manual && automaticTitle(title) && filename != "" {
		title = filename
	}
	if !found || size == 0 || !valid(title, 200) {
		return fail(400, "文件为空或标题无效")
	}
	if _, err = a.DB.Exec("INSERT INTO tasks(id,source,title,kind,title_manual) VALUES(?,?,?,'upload',?)", id, path, title, manual); err != nil {
		return err
	}
	success = true
	reply(w, 200, map[string]string{"id": id, "state": "queued"})
	return nil
}
func (a *App) retry(w http.ResponseWriter, r *http.Request, _ string) error {
	tx, err := a.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var state, source string
	err = tx.QueryRow("SELECT state,source FROM tasks WHERE id=?", r.PathValue("id")).Scan(&state, &source)
	if errors.Is(err, sql.ErrNoRows) {
		return fail(404, "任务不存在")
	}
	if err != nil {
		return err
	}
	if state != "failed" {
		return fail(409, "只有失败任务可以重试")
	}
	var count int
	if err = tx.QueryRow("SELECT COUNT(*) FROM tasks WHERE source=? AND state NOT IN ('failed','cancelled')", source).Scan(&count); err != nil {
		return err
	}
	if count > 0 {
		return fail(409, "同一来源已有任务")
	}
	if _, err = tx.Exec("UPDATE tasks SET state='queued',phase='queued',error=NULL,error_code=NULL,next_attempt_at=0,auto_retries=0 WHERE id=?", r.PathValue("id")); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	reply(w, 200, map[string]bool{"ok": true})
	return nil
}
func (a *App) editVideo(w http.ResponseWriter, r *http.Request, _ string) error {
	var b struct {
		Title       string
		Description *string
	}
	if err := decode(r, &b); err != nil {
		return err
	}
	if !valid(b.Title, 200) {
		return fail(400, "视频标题不能为空，且不能超过 200 字")
	}
	if b.Description != nil && len([]rune(*b.Description)) > 4000 {
		return fail(400, "描述不能超过 4000 字")
	}
	result, err := a.DB.Exec("UPDATE videos SET title=?,description=COALESCE(?,description),published=1 WHERE id=?", b.Title, b.Description, r.PathValue("id"))
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return fail(404, "视频不存在")
	}
	reply(w, 200, map[string]bool{"ok": true})
	return nil
}
func (a *App) collections(w http.ResponseWriter, r *http.Request, role string) error {
	items, err := query(a.DB, "SELECT * FROM collections ORDER BY rowid DESC")
	if err != nil {
		return err
	}
	result := make([]map[string]any, 0)
	for _, c := range items {
		videos, e := query(a.DB, "SELECT v.* FROM collection_items i JOIN videos v ON v.id=i.video_id WHERE i.collection_id=? ORDER BY i.position", c["id"])
		if e != nil {
			return e
		}
		for _, v := range videos {
			a.present(v, role)
		}
		c["videos"] = videos
		if role == "admin" || len(videos) > 0 {
			result = append(result, c)
		}
	}
	reply(w, 200, result)
	return nil
}
func (a *App) createCollection(w http.ResponseWriter, r *http.Request, _ string) error {
	var b struct {
		Title    string
		VideoIDs []string `json:"video_ids"`
	}
	if err := decode(r, &b); err != nil {
		return err
	}
	if !valid(b.Title, 100) || len(b.VideoIDs) > 500 {
		return fail(400, "合集内容格式无效")
	}
	id := ID()
	tx, err := a.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec("INSERT INTO collections VALUES(?,?)", id, b.Title); err != nil {
		return err
	}
	seen := map[string]bool{}
	position := 0
	for _, vid := range b.VideoIDs {
		if seen[vid] {
			continue
		}
		seen[vid] = true
		var exists int
		if err = tx.QueryRow("SELECT COUNT(*) FROM videos WHERE id=?", vid).Scan(&exists); err != nil {
			return err
		}
		if exists == 0 {
			return fail(400, "合集包含不存在的视频")
		}
		if _, err = tx.Exec("INSERT INTO collection_items VALUES(?,?,?)", id, vid, position); err != nil {
			return err
		}
		position++
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	reply(w, 200, map[string]string{"id": id})
	return nil
}
func (a *App) media(w http.ResponseWriter, r *http.Request, _ string) error {
	id, res := r.PathValue("id"), r.PathValue("resource")
	q := r.URL.Query()
	expires, err := strconv.ParseInt(q.Get("expires"), 10, 64)
	role := q.Get("role")
	if err != nil || (res != "video" && res != "thumbnail" && res != "stream.m3u8" && !streamResource.MatchString(res)) || expires < time.Now().Unix() || !hmac.Equal([]byte(q.Get("sig")), []byte(a.signature(id, res, expires, role))) {
		return fail(403, "播放授权无效或过期，请刷新目录")
	}

	var name string
	err = a.DB.QueryRow("SELECT path FROM videos WHERE id=?", id).Scan(&name)
	if errors.Is(err, sql.ErrNoRows) {
		return fail(404, "视频不存在或已删除")
	}
	if err != nil {
		return err
	}
	if !safeVideoID.MatchString(id) {
		return fail(404, "视频不存在")
	}
	if res == "stream.m3u8" {
		return a.servePlaylist(w, r, id, role, expires)
	}
	folder, contentType := "videos", "video/mp4"
	if streamResource.MatchString(res) {
		folder = filepath.Join("streams", id)
		name = res
		contentType = "video/mp2t"
	}
	if res == "thumbnail" {
		folder = "thumbnails"
		name = id + ".jpg"
		contentType = "image/jpeg"
	}
	if filepath.Base(name) != name {
		return fail(404, "文件不可用")
	}
	f, err := os.Open(filepath.Join(a.Config.Data, folder, name))
	if os.IsNotExist(err) {
		return fail(404, "文件不可用")
	}
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, no-cache")
	http.ServeContent(w, r, name, info.ModTime(), f)
	return nil
}
