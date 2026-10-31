package family

// Web 管理台：系统运行信息、抖音 Cookie 配置与内嵌单页界面。
// Cookie 只写不读：任何接口不得返回凭证内容或签名源地址。

import (
	"context"
	"embed"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

//go:embed admin.html
var adminFiles embed.FS

const serverVersion = "0.10.0"

// f2ConfigPath 返回生效的抖音下载配置文件路径，与 resolver.go 的读取逻辑一致。
func (a *App) f2ConfigPath() string {
	if a.Config.F2Config != "" {
		if filepath.IsAbs(a.Config.F2Config) {
			return a.Config.F2Config
		}
		return filepath.Join(a.Config.Root, a.Config.F2Config)
	}
	return filepath.Join(a.Config.Data, "private", "f2.yaml")
}

func (a *App) adminPage(w http.ResponseWriter, r *http.Request, _ string) error {
	page, err := adminFiles.ReadFile("admin.html")
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(page)
	return nil
}

const usageCacheTTL = 30 * time.Second

type dirUsage struct {
	Name  string `json:"name"`
	Bytes int64  `json:"bytes"`
	Files int    `json:"files"`
}

func dirUsageOf(root string) dirUsage {
	usage := dirUsage{Name: filepath.Base(root)}
	err := filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		if info, e := d.Info(); e == nil {
			usage.Bytes += info.Size()
			usage.Files++
		}
		return nil
	})
	if err != nil {
		return usage
	}
	return usage
}

func toolAvailable(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func (a *App) systemInfo(w http.ResponseWriter, r *http.Request, _ string) error {
	info := map[string]any{
		"version":    serverVersion,
		"backend":    "go",
		"data_dir":   a.Config.Data,
		"started_at": a.startedAt.UTC().Format(time.RFC3339),
	}
	if a.startedAt.After(time.Time{}) {
		info["uptime_seconds"] = int64(time.Since(a.startedAt).Seconds())
	}
	if free, err := a.FreeSpace(a.Config.Data); err == nil {
		info["disk_free_bytes"] = free
	}

	// The overview refreshes every 20 seconds; walking every HLS segment each
	// time is wasteful on a large library.
	a.usageMu.Lock()
	var usages []dirUsage
	var total int64
	if time.Since(a.usageAt) < usageCacheTTL {
		usages = append([]dirUsage(nil), a.usage...)
		total = a.usageTotal
	} else {
		names := []string{"database", "videos", "thumbnails", "streams", "temp", "download-cache", "backups", "releases", "quarantine"}
		usages = make([]dirUsage, 0, len(names))
		for _, name := range names {
			u := dirUsageOf(filepath.Join(a.Config.Data, name))
			total += u.Bytes
			usages = append(usages, u)
		}
		sort.Slice(usages, func(i, j int) bool { return usages[i].Bytes > usages[j].Bytes })
		a.usage = append([]dirUsage(nil), usages...)
		a.usageTotal = total
		a.usageAt = time.Now()
	}
	a.usageMu.Unlock()
	info["usage"] = usages
	info["usage_total_bytes"] = total

	var videoCount int
	a.DB.QueryRow("SELECT COUNT(*) FROM videos").Scan(&videoCount)
	info["video_count"] = videoCount

	states := map[string]int{}
	if rows, err := a.DB.Query("SELECT state, COUNT(*) FROM tasks GROUP BY state"); err == nil {
		for rows.Next() {
			var state string
			var n int
			if rows.Scan(&state, &n) == nil {
				states[state] = n
			}
		}
		rows.Close()
	}
	info["tasks"] = states

	douyinConfigured := false
	if st, err := os.Stat(a.f2ConfigPath()); err == nil && st.Mode().IsRegular() {
		douyinConfigured = true
	}
	python := a.downloaderPythonPath()
	_, pythonMissing := os.Stat(python)
	info["tools"] = map[string]any{
		"ffmpeg":            toolAvailable("ffmpeg"),
		"ffprobe":           toolAvailable("ffprobe"),
		"downloader":        pythonMissing == nil,
		"douyin_configured": douyinConfigured,
	}
	reply(w, 200, info)
	return nil
}

func (a *App) douyinConfig(w http.ResponseWriter, r *http.Request, _ string) error {
	info := map[string]any{"configured": false, "updated_at": ""}
	if st, err := os.Stat(a.f2ConfigPath()); err == nil && st.Mode().IsRegular() {
		info["configured"] = true
		info["updated_at"] = st.ModTime().UTC().Format(time.RFC3339)
	}
	reply(w, 200, info)
	return nil
}

func (a *App) saveDouyinConfig(w http.ResponseWriter, r *http.Request, _ string) error {
	var b struct{ Cookie string }
	if err := decode(r, &b); err != nil {
		return err
	}
	cookie := strings.TrimSpace(b.Cookie)
	cookie = strings.ReplaceAll(cookie, "\r", "")
	cookie = strings.ReplaceAll(cookie, "\n", " ")
	if cookie == "" {
		return fail(400, "Cookie 不能为空")
	}
	if len(cookie) > 65536 {
		return fail(400, "Cookie 内容过长")
	}
	path := a.f2ConfigPath()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	// 单引号 YAML 标量：内部单引号按 YAML 规则翻倍转义。
	body := "# 由网页管理台生成。请勿提交到仓库或发送给他人。\ndouyin:\n  cookie: '" + strings.ReplaceAll(cookie, "'", "''") + "'\n"
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	reply(w, 200, map[string]bool{"ok": true})
	return nil
}

// testDouyinConfig 用一条真实分享链接验证登录配置，只返回标题等安全字段。
func (a *App) testDouyinConfig(w http.ResponseWriter, r *http.Request, _ string) error {
	var b struct{ URL string }
	if err := decode(r, &b); err != nil {
		return err
	}
	source, err := ExtractURL(b.URL)
	if err != nil {
		reply(w, 200, map[string]any{"ok": false, "code": "invalid_url", "message": "请粘贴抖音分享链接"})
		return nil
	}
	ctx, cancel := context.WithTimeout(r.Context(), 80*time.Second)
	defer cancel()
	video, err := a.ResolveVideo(ctx, source)
	if err != nil {
		code, message := "resolve_failed", "暂时无法解析作品"
		var de *downloadError
		if errors.As(err, &de) {
			code, message = de.Code, de.Message
		}
		reply(w, 200, map[string]any{"ok": false, "code": code, "message": message})
		return nil
	}
	reply(w, 200, map[string]any{"ok": true, "id": video.ID, "title": video.Title, "sources": len(video.URLs)})
	return nil
}

// ---------- 客户端安装包 ----------

var appDefs = []struct{ App, Label, Dir string }{
	{"parent", "家长端", "parent_app"},
	{"kids", "儿童端（抖音儿童版）", "kids_app"},
	{"tv", "电视端（轻量版）", "tv_app"},
}
