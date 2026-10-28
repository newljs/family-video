package family

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/gofrs/flock"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type APKRelease struct {
	App     string `json:"app"`
	Version string `json:"version"`
	Package string `json:"package"`
	Build   int64  `json:"build"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size_bytes"`
	Created string `json:"created_at"`
}

var apkPackage = regexp.MustCompile(`package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'`)

func validClientApp(app string) bool {
	for _, def := range appDefs {
		if def.App == app {
			return true
		}
	}
	return false
}

// PublishAPK inspects the actual binary rather than the working tree pubspec.
// aapt is supplied by Android SDK build-tools. No signing keys enter the server.
func PublishAPK(c Config, app, source, aapt string) (APKRelease, error) {
	if !validClientApp(app) {
		return APKRelease{}, fmt.Errorf("未知客户端")
	}
	return stageAPKChecked(c, APKRelease{App: app}, source, func(snapshot string) (APKRelease, error) {
		raw, err := command(context.Background(), 30*time.Second, aapt, "dump", "badging", snapshot)
		if err != nil {
			return APKRelease{}, fmt.Errorf("无法读取 APK 元数据，请检查 Android SDK aapt: %w", err)
		}
		match := apkPackage.FindStringSubmatch(string(raw))
		if len(match) != 4 || match[1] != "cn.familyvideo."+app+"_app" {
			return APKRelease{}, fmt.Errorf("APK 包名或版本元数据无效")
		}
		build, err := strconv.ParseInt(match[2], 10, 64)
		if err != nil || build <= 0 {
			return APKRelease{}, fmt.Errorf("APK versionCode 无效")
		}
		return APKRelease{App: app, Package: match[1], Version: match[3] + "+" + match[2], Build: build}, nil
	})
}

func stageAPK(c Config, release APKRelease, source string) (APKRelease, error) {
	return stageAPKChecked(c, release, source, nil)
}

func stageAPKChecked(c Config, release APKRelease, source string, inspect func(string) (APKRelease, error)) (APKRelease, error) {
	root := filepath.Join(c.Data, "releases", release.App)
	if err := os.MkdirAll(root, 0700); err != nil {
		return release, err
	}
	lock := flock.New(filepath.Join(root, "publish.lock"))
	ok, err := lock.TryLock()
	if err != nil {
		return release, err
	}
	if !ok {
		return release, fmt.Errorf("另一个安装包发布正在进行，请稍后重试")
	}
	defer lock.Unlock()
	in, err := os.Open(source)
	if err != nil {
		return release, err
	}
	defer in.Close()
	out, err := os.CreateTemp(root, "apk-*.tmp")
	if err != nil {
		return release, err
	}
	defer os.Remove(out.Name())
	digest := sha256.New()
	release.Size, err = io.Copy(io.MultiWriter(out, digest), in)
	if err == nil {
		err = out.Sync()
	}
	closeErr := out.Close()
	if err != nil {
		return release, err
	}
	if closeErr != nil {
		return release, closeErr
	}
	if inspect != nil {
		metadata, err := inspect(out.Name())
		if err != nil {
			return release, err
		}
		release.Version, release.Build, release.Package = metadata.Version, metadata.Build, metadata.Package
	}
	if release.Size == 0 {
		return release, fmt.Errorf("APK 为空")
	}
	release.SHA256 = hex.EncodeToString(digest.Sum(nil))
	if raw, readErr := os.ReadFile(filepath.Join(root, "release.json")); readErr == nil {
		var previous APKRelease
		if json.Unmarshal(raw, &previous) == nil && previous.SHA256 != release.SHA256 && release.Build <= previous.Build {
			return release, fmt.Errorf("发布新 APK 前必须递增 versionCode，当前已发布构建号为 %d", previous.Build)
		}
	}
	target := filepath.Join(root, release.SHA256+".apk")
	if _, err = os.Stat(target); os.IsNotExist(err) {
		if err = os.Rename(out.Name(), target); err != nil {
			return release, err
		}
	}
	release.Created = time.Now().UTC().Format(time.RFC3339)
	raw, err := json.MarshalIndent(release, "", "  ")
	if err != nil {
		return release, err
	}
	tmp, err := os.CreateTemp(root, "release-*.tmp")
	if err != nil {
		return release, err
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(raw)
	if err == nil {
		err = tmp.Sync()
	}
	closeErr = tmp.Close()
	if err != nil {
		return release, err
	}
	if closeErr != nil {
		return release, closeErr
	}
	return release, os.Rename(tmp.Name(), filepath.Join(root, "release.json"))
}

func openRelease(c Config, app string) (APKRelease, *os.File, error) {
	var release APKRelease
	root := filepath.Join(c.Data, "releases", app)
	raw, err := os.ReadFile(filepath.Join(root, "release.json"))
	if err != nil {
		return release, nil, err
	}
	if err = json.Unmarshal(raw, &release); err != nil {
		return release, nil, err
	}
	digest, err := hex.DecodeString(release.SHA256)
	if err != nil || len(digest) != sha256.Size || release.App != app || release.Size <= 0 || release.Version == "" {
		return release, nil, fmt.Errorf("安装包发布清单无效")
	}
	f, err := os.Open(filepath.Join(root, release.SHA256+".apk"))
	if err != nil {
		return release, nil, err
	}
	hash := sha256.New()
	size, err := io.Copy(hash, f)
	if err != nil || size != release.Size || hex.EncodeToString(hash.Sum(nil)) != release.SHA256 {
		f.Close()
		return release, nil, fmt.Errorf("安装包完整性校验失败，请重新发布")
	}
	if _, err = f.Seek(0, 0); err != nil {
		f.Close()
		return release, nil, err
	}
	return release, f, nil
}

func (a *App) releaseInfo(app, label string) map[string]any {
	item := map[string]any{"app": app, "label": label, "available": false}
	release, f, err := openRelease(a.Config, app)
	if err != nil {
		item["note"] = "尚无有效发布包，请运行 scripts/build-android.ps1 -Publish（电视端用 scripts/build-tv.ps1 -Publish）；已有 APK 可用 family-video publish-apk 发布。"
		return item
	}
	f.Close()
	item["available"], item["version"], item["size_bytes"] = true, release.Version, release.Size
	item["sha256"], item["build"], item["updated_at"] = release.SHA256, release.Build, release.Created
	item["url"] = "api/apps/" + app + "/download?sha256=" + release.SHA256
	return item
}

func (a *App) updateCheck(w http.ResponseWriter, r *http.Request, _ string) error {
	for _, def := range appDefs {
		if def.App == r.PathValue("app") {
			reply(w, 200, a.releaseInfo(def.App, def.Label))
			return nil
		}
	}
	return fail(404, "未知的客户端类型")
}

func (a *App) listApps(w http.ResponseWriter, r *http.Request, _ string) error {
	items := make([]map[string]any, 0, len(appDefs))
	for _, def := range appDefs {
		items = append(items, a.releaseInfo(def.App, def.Label))
	}
	reply(w, 200, items)
	return nil
}

func (a *App) downloadApp(w http.ResponseWriter, r *http.Request, _ string) error {
	app := r.PathValue("app")
	if !validClientApp(app) {
		return fail(404, "未知的客户端类型")
	}
	release, f, err := openRelease(a.Config, app)
	if err != nil {
		return fail(404, "没有有效的安装包，请先构建并发布")
	}
	defer f.Close()
	if expected := r.URL.Query().Get("sha256"); expected != "" && expected != release.SHA256 {
		return fail(409, "安装包已更新，请重新检查更新后下载")
	}
	info, err := f.Stat()
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "application/vnd.android.package-archive")
	w.Header().Set("ETag", `"`+release.SHA256+`"`)
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": "family-video-" + app + "-" + strings.ReplaceAll(release.Version, "/", "_") + ".apk"}))
	http.ServeContent(w, r, info.Name(), info.ModTime(), f)
	return nil
}
