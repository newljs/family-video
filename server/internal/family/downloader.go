package family

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Upstream output may contain cookies and signed URLs. Keep a bounded in-memory
// tail for classification only; never put it into logs or task responses.
type downloadOutput struct {
	mu   sync.Mutex
	tail []byte
}

func (o *downloadOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	const limit = 64 * 1024
	n := len(p)
	if len(p) > limit {
		p = p[len(p)-limit:]
	}
	o.tail = append(o.tail, p...)
	if len(o.tail) > limit {
		o.tail = o.tail[len(o.tail)-limit:]
	}
	return n, nil
}

func (a *App) download(ctx context.Context, source, folder string) (string, error) {
	if err := os.MkdirAll(folder, 0700); err != nil {
		return "", derror("storage", "无法创建下载目录", false)
	}
	c, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	a.progress(c, "cached", 0, 0)
	if path, ok := a.cachedSource(c, source, folder); ok {
		return path, nil
	}
	if c.Err() != nil {
		return "", c.Err()
	}
	var last error
	for round := 0; round < 2; round++ {
		if round > 0 {
			select {
			case <-c.Done():
				return "", c.Err()
			case <-time.After(2 * time.Second):
			}
		}
		a.progress(c, "resolving", 0, 0)
		video, err := a.ResolveVideo(c, source)
		if err != nil {
			return "", err
		}
		if video.ID != "" {
			if len(video.ID) > 128 || !safeVideoID.MatchString(video.ID) {
				return "", derror("invalid_source", "下载器返回的作品标识无效", false)
			}
			var existing string
			err = a.DB.QueryRow("SELECT video_id FROM video_sources WHERE platform='douyin' AND source_id=?", video.ID).Scan(&existing)
			if err == nil {
				return "", &duplicateVideo{VideoID: existing}
			}
			if !errors.Is(err, sql.ErrNoRows) {
				return "", err
			}
		}
		writeMetadata(folder, videoMetadata{Title: video.Title, Description: video.Title, SourceID: video.ID})
		var retryable bool
		for _, candidate := range video.URLs {
			target := filepath.Join(folder, "source.mp4")
			err = a.transfer(c, candidate, video.Headers, target)
			if err == nil {
				return target, nil
			}
			if c.Err() != nil {
				return "", c.Err()
			}
			last = err
			var de *downloadError
			if errors.As(err, &de) {
				if de.Code == "rate_limited" {
					return "", err
				}
				if !de.Retryable {
					return "", err
				}
				retryable = true
			}
		}
		if !retryable {
			break
		}
	}
	if last != nil {
		return "", last
	}
	return "", derror("no_source", "没有可用视频源，请确认作品链接", false)
}
