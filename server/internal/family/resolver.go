package family

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

type resolvedVideo struct {
	ID      string            `json:"id"`
	Title   string            `json:"title"`
	URLs    []string          `json:"urls"`
	Headers map[string]string `json:"headers"`
	Error   *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type downloadError struct {
	Code, Message string
	Retryable     bool
	RetryAfter    time.Duration
}

func (e *downloadError) Error() string { return e.Message }
func derror(code, message string, retry bool) error {
	return &downloadError{Code: code, Message: message, Retryable: retry}
}

func (a *App) downloaderPythonPath() string {
	if a.Config.ResolverPython != "" {
		return a.Config.ResolverPython
	}
	name := "python"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(filepath.Dir(a.Config.F2Exe), name)
}

func (a *App) resolveF2(ctx context.Context, source string) (resolvedVideo, error) {
	var video resolvedVideo
	python := a.downloaderPythonPath()
	script := filepath.Join(a.Config.Root, "server", "downloader", "resolve.py")
	if _, err := os.Stat(python); err != nil {
		return video, derror("setup_required", "下载器未安装，请运行 scripts/setup-downloader.ps1", false)
	}
	if _, err := os.Stat(script); err != nil {
		return video, derror("setup_required", "下载解析脚本缺失，请使用完整服务端目录启动", false)
	}
	config := a.Config.F2Config
	if config == "" {
		candidate := filepath.Join(a.Config.Data, "private", "f2.yaml")
		if _, err := os.Stat(candidate); err == nil {
			config = candidate
		}
	}
	args := []string{script, "--url", source}
	if config != "" {
		if !filepath.IsAbs(config) {
			config = filepath.Join(a.Config.Root, config)
		}
		args = append(args, "--config", config)
	}
	c, cancel := context.WithTimeout(ctx, 75*time.Second)
	defer cancel()
	cmd := exec.CommandContext(c, python, args...)
	cmd.Dir = a.Config.Data
	cmd.Env = append(os.Environ(), "PYTHONIOENCODING=utf-8")
	out := &downloadOutput{}
	cmd.Stdout, cmd.Stderr = out, io.Discard
	err := cmd.Run()
	if c.Err() != nil {
		if errors.Is(c.Err(), context.Canceled) {
			return video, c.Err()
		}
		return video, derror("resolve_timeout", "解析作品超时，稍后自动重试", true)
	}
	if json.Unmarshal(out.tail, &video) != nil {
		return video, derror("resolver_protocol", "下载解析器返回无效数据，请检查下载器安装", false)
	}
	if video.Error != nil {
		// Never trust arbitrary upstream messages. Only a fixed, local mapping
		// may reach the API; the resolver protocol contains signed URLs.
		messages := map[string]string{
			"login_required": "抖音作品接口拒绝访问，请检查电脑上的抖音登录配置",
			"rate_limited":   "抖音请求过于频繁，稍后自动重试",
			"not_found":      "作品不存在、已删除或不可访问",
			"unsupported":    "该作品没有可下载视频，可能为图集或已不可访问",
			"setup_required": "下载器依赖不完整，请运行 scripts/setup-downloader.ps1",
			"config_error":   "抖音下载配置无法读取，请检查电脑上的配置文件",
			"network_error":  "连接抖音作品接口失败，稍后自动重试",
			"resolve_failed": "暂时无法解析作品，请确认分享链接并检查下载器适配",
		}
		message, ok := messages[video.Error.Code]
		if !ok {
			return video, derror("resolver_protocol", "下载解析器返回未知错误，请检查下载器适配", false)
		}
		return video, derror(video.Error.Code, message, video.Error.Code == "rate_limited" || video.Error.Code == "network_error")
	}
	if err != nil || video.ID == "" || len(video.ID) > 100 || len(video.URLs) == 0 || len(video.URLs) > 8 {
		return video, derror("resolve_failed", "未解析到有效视频地址", false)
	}
	for _, u := range video.URLs {
		if len(u) > 8192 {
			return video, fmt.Errorf("视频源地址长度无效")
		}
	}
	return video, nil
}

type taskContextKey struct{}

func (a *App) progress(ctx context.Context, phase string, received, total int64) {
	if id, ok := ctx.Value(taskContextKey{}).(string); ok {
		a.DB.ExecContext(ctx, "UPDATE tasks SET phase=?,downloaded_bytes=?,total_bytes=? WHERE id=? AND state='running'", phase, received, total, id)
	}
}
