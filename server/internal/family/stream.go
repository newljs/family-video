package family

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var streamResource = regexp.MustCompile(`^segment[0-9]{5,8}\.ts$`)
var safeVideoID = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,80}$`)

func (a *App) streamURL(id, resource, role string, expires int64) string {
	return fmt.Sprintf("/media/%s/%s?expires=%d&role=%s&sig=%s", id, resource, expires, role, a.signature(id, resource, expires, role))
}

// Package the existing H.264/AAC file without re-encoding. Each segment is
// independently requested by the native streaming player.
func (a *App) makeStream(ctx context.Context, id, path string) (string, error) {
	if !safeVideoID.MatchString(id) {
		return "", fmt.Errorf("视频标识无效")
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	free, err := a.FreeSpace(a.Config.Data)
	if err != nil || free < uint64(info.Size())+512*1024*1024 {
		return "", fmt.Errorf("流媒体分片空间不足")
	}
	root, err := os.MkdirTemp(filepath.Join(a.Config.Data, "temp"), "stream-")
	if err != nil {
		return "", err
	}
	args := []string{"-v", "error", "-y", "-i", path, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-hls_time", "4", "-hls_list_size", "0", "-hls_playlist_type", "vod", "-hls_segment_filename", filepath.Join(root, "segment%05d.ts"), filepath.Join(root, "index.m3u8")}
	if _, err = command(ctx, 5*time.Minute, "ffmpeg", args...); err != nil {
		os.RemoveAll(root)
		return "", fmt.Errorf("流媒体分片失败，请检查 FFmpeg 和空间")
	}
	return root, nil
}

func (a *App) installStream(id, root string) error {
	target := filepath.Join(a.Config.Data, "streams", id)
	if _, err := os.Stat(target); err == nil {
		return fmt.Errorf("流媒体目录已存在")
	}
	return os.Rename(root, target)
}

// Existing libraries are upgraded in the same single background worker, one
// video at a time, so API requests never wait for FFmpeg.
func (a *App) backfillStream(ctx context.Context) (bool, error) {
	var id, name string
	err := a.DB.QueryRow("SELECT id,path FROM videos WHERE stream_state='pending' ORDER BY created_at LIMIT 1").Scan(&id, &name)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if filepath.Base(name) != name || !safeVideoID.MatchString(id) {
		return false, fmt.Errorf("视频路径无效")
	}
	if info, e := os.Stat(filepath.Join(a.Config.Data, "streams", id, "index.m3u8")); e == nil && info.Mode().IsRegular() {
		_, err = a.DB.Exec("UPDATE videos SET stream_state='ready' WHERE id=?", id)
		return true, err
	}
	root, err := a.makeStream(ctx, id, filepath.Join(a.Config.Data, "videos", name))
	if root != "" {
		defer os.RemoveAll(root)
	}
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	if err != nil {
		_, e := a.DB.Exec("UPDATE videos SET stream_state='failed' WHERE id=?", id)
		return true, e
	}
	a.mediaMu.Lock()
	defer a.mediaMu.Unlock()
	var n int
	if e := a.DB.QueryRow("SELECT COUNT(*) FROM videos WHERE id=?", id).Scan(&n); e != nil {
		return true, e
	}
	if n == 0 {
		return true, nil
	}
	if err = a.installStream(id, root); err != nil {
		_, e := a.DB.Exec("UPDATE videos SET stream_state='failed' WHERE id=?", id)
		return true, e
	}
	_, err = a.DB.Exec("UPDATE videos SET stream_state='ready' WHERE id=?", id)
	return true, err
}

func (a *App) servePlaylist(w http.ResponseWriter, r *http.Request, id, role string, expires int64) error {
	raw, err := os.ReadFile(filepath.Join(a.Config.Data, "streams", id, "index.m3u8"))
	if os.IsNotExist(err) {
		return fail(404, "流媒体尚未准备好，请刷新后重试")
	}
	if err != nil {
		return err
	}
	lines := strings.Split(string(raw), "\n")
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !streamResource.MatchString(line) {
			return fail(500, "流媒体清单无效")
		}
		lines[i] = a.streamURL(id, line, role, expires)
	}
	data := strings.Join(lines, "\n")
	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "private, no-cache")
	http.ServeContent(w, r, "index.m3u8", time.Time{}, strings.NewReader(data))
	return nil
}
