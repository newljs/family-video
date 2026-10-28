package family

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/gofrs/flock"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type duplicateVideo struct{ VideoID string }

func (e *duplicateVideo) Error() string { return "作品已在视频库中" }

func (a *App) StartWorker(ctx context.Context) (func(), error) {
	lock := flock.New(filepath.Join(a.Config.Data, "worker.lock"))
	ok, err := lock.TryLock()
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("另一个下载任务进程正在运行")
	}
	if _, err = a.DB.Exec("UPDATE tasks SET state='queued',phase='queued',next_attempt_at=0 WHERE state='running'"); err != nil {
		lock.Unlock()
		return nil, err
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer lock.Unlock()
		var lastMaintenance time.Time
		for ctx.Err() == nil {
			worked, e := a.RunOnce(ctx)
			if e != nil {
				log.Printf("worker: %v", e)
			}
			if !worked && e == nil && ctx.Err() == nil {
				if time.Since(lastMaintenance) >= time.Hour {
					lastMaintenance = time.Now()
					if err := a.dailySnapshot(); err != nil {
						log.Printf("database snapshot: %v", err)
					}
				}
				a.mediaMu.Lock()
				a.cleanupDeleted()
				a.mediaMu.Unlock()
				worked, e = a.backfillStream(ctx)
			}
			if !worked || e != nil {
				select {
				case <-ctx.Done():
					return
				case <-time.After(2 * time.Second):
				}
			}
		}
	}()
	return func() { <-done }, nil
}

func command(ctx context.Context, timeout time.Duration, name string, args ...string) ([]byte, error) {
	c, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return exec.CommandContext(c, name, args...).Output()
}

type probe struct {
	Streams []struct {
		Type          string `json:"codec_type"`
		Codec         string `json:"codec_name"`
		Width, Height int
	}
	Format struct {
		Duration string
		Tags     map[string]string
	}
}

func inspect(ctx context.Context, path string) (probe, error) {
	raw, err := command(ctx, 30*time.Second, "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path)
	var p probe
	if err != nil {
		return p, err
	}
	err = json.Unmarshal(raw, &p)
	return p, err
}

func (a *App) RunOnce(ctx context.Context) (bool, error) {
	tx, err := a.DB.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var id, source, title, kind string
	var autoRetries int
	var manual bool
	var share string
	err = tx.QueryRow("SELECT id,source,title,kind,auto_retries,share_text,title_manual FROM tasks WHERE state='queued' AND next_attempt_at<=? ORDER BY created_at,rowid LIMIT 1", time.Now().Unix()).Scan(&id, &source, &title, &kind, &autoRetries, &share, &manual)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if _, err = tx.Exec("UPDATE tasks SET state='running',phase='resolving',downloaded_bytes=0,total_bytes=0,attempts=attempts+1,error=NULL,error_code=NULL,next_attempt_at=0 WHERE id=?", id); err != nil {
		return false, err
	}
	if err = tx.Commit(); err != nil {
		return false, err
	}
	taskContext, cancel := context.WithCancel(ctx)
	a.taskMu.Lock()
	a.activeTasks[id] = cancel
	a.taskMu.Unlock()
	defer func() { cancel(); a.taskMu.Lock(); delete(a.activeTasks, id); a.taskMu.Unlock() }()
	var currentState string
	if err = a.DB.QueryRow("SELECT state FROM tasks WHERE id=?", id).Scan(&currentState); err != nil {
		return true, err
	}
	if currentState == "cancelled" {
		a.cleanupImport(id, kind)
		return true, nil
	}
	parentContext := ctx
	ctx = context.WithValue(taskContext, taskContextKey{}, id)
	videoID := ID()
	folder := filepath.Join(a.Config.Data, "temp", id)
	target := filepath.Join(a.Config.Data, "videos", videoID+".mp4")
	cover := filepath.Join(a.Config.Data, "thumbnails", videoID+".jpg")
	process := func() error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err = os.MkdirAll(folder, 0700); err != nil {
			return err
		}
		path := source
		if kind == "douyin" {
			path, err = a.DownloadVideo(ctx, source, folder)
			if err != nil {
				return err
			}
			if identity := readMetadata(folder).SourceID; identity != "" {
				var existing string
				e := a.DB.QueryRow("SELECT video_id FROM video_sources WHERE platform='douyin' AND source_id=?", identity).Scan(&existing)
				if e == nil {
					return &duplicateVideo{VideoID: existing}
				}
				if !errors.Is(e, sql.ErrNoRows) {
					return e
				}
			}
		}
		info, e := os.Stat(path)
		if e != nil {
			return fmt.Errorf("源文件不存在，请重新上传")
		}
		free, e := a.FreeSpace(a.Config.Data)
		if e != nil {
			return e
		}
		required := uint64(info.Size()) * 3
		if required < 1024*1024*1024 {
			required = 1024 * 1024 * 1024
		}
		if free < required {
			return fmt.Errorf("磁盘空间不足，请先清理视频库")
		}
		a.progress(ctx, "inspecting", 0, 0)
		p, e := inspect(ctx, path)
		if e != nil {
			return fmt.Errorf("视频检查失败，请检查文件格式与 FFmpeg")
		}
		hasVideo, compatible := false, true
		var sourceWidth, sourceHeight int
		for _, s := range p.Streams {
			if s.Type == "video" {
				hasVideo = true
				if sourceWidth == 0 {
					sourceWidth, sourceHeight = s.Width, s.Height
				}
			}
			if (s.Type == "video" && s.Codec != "h264") || (s.Type == "audio" && s.Codec != "aac") {
				compatible = false
			}
		}
		if !hasVideo {
			return fmt.Errorf("文件不包含视频轨道")
		}
		if kind == "douyin" {
			a.cacheSource(ctx, source, path)
		}
		metadata := chooseMetadata(title, manual, share, readMetadata(folder), p)
		title = metadata.Title
		a.progress(ctx, "processing", 0, 0)
		if compatible {
			args := []string{"-v", "error", "-y", "-i", path, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-movflags", "+faststart", target}
			if _, e = command(ctx, 15*time.Minute, "ffmpeg", args...); e != nil {
				return fmt.Errorf("视频处理失败，请检查 FFmpeg 与磁盘空间")
			}
		} else if e = a.encodeVideo(ctx, path, target, sourceWidth, sourceHeight); e != nil {
			return e
		}
		p, e = inspect(ctx, target)
		if e != nil {
			return e
		}
		var duration float64
		if _, e = fmt.Sscan(p.Format.Duration, &duration); e != nil || duration <= 0 {
			return fmt.Errorf("视频时长无效")
		}
		width, height := 0, 0
		for _, s := range p.Streams {
			if s.Type == "video" {
				width, height = s.Width, s.Height
				break
			}
		}
		a.progress(ctx, "thumbnail", 0, 0)
		if _, e = command(ctx, 30*time.Second, "ffmpeg", "-v", "error", "-y", "-i", target, "-frames:v", "1", "-vf", "scale=480:-2", cover); e != nil {
			return fmt.Errorf("封面生成失败")
		}
		a.progress(ctx, "streaming", 0, 0)
		streamRoot, e := a.makeStream(ctx, videoID, target)
		if e != nil {
			return e
		}
		defer os.RemoveAll(streamRoot)
		a.mediaMu.Lock()
		defer a.mediaMu.Unlock()
		if e = a.installStream(videoID, streamRoot); e != nil {
			return e
		}
		var sourceURL any
		if kind == "douyin" {
			sourceURL = source
		}
		save, e := a.DB.BeginTx(ctx, nil)
		if e != nil {
			return e
		}
		defer save.Rollback()
		if _, e = save.Exec("INSERT INTO videos(id,title,description,source_url,path,duration,width,height,published,stream_state) VALUES(?,?,?,?,?,?,?,?,1,'ready')", videoID, title, metadata.Description, sourceURL, filepath.Base(target), duration, width, height); e != nil {
			return e
		}
		if e = indexVideo(save, videoID, title, metadata.Description); e != nil {
			return e
		}
		if identity := readMetadata(folder).SourceID; kind == "douyin" && identity != "" {
			if _, e = save.Exec("INSERT INTO video_sources(video_id,platform,source_id) VALUES(?,'douyin',?)", videoID, identity); e != nil {
				return e
			}
		}
		result, e := save.Exec("UPDATE tasks SET state='completed',phase='completed',next_attempt_at=0,error=NULL,error_code=NULL,title=?,video_id=? WHERE id=? AND state='running'", title, videoID, id)
		if e != nil {
			return e
		}
		count, _ := result.RowsAffected()
		if count != 1 {
			return fmt.Errorf("任务已取消")
		}
		return save.Commit()
	}
	if e := process(); e != nil {
		os.Remove(target)
		os.Remove(cover)
		os.RemoveAll(filepath.Join(a.Config.Data, "streams", videoID))
		var duplicate *duplicateVideo
		if errors.As(e, &duplicate) {
			result, updateErr := a.DB.Exec("UPDATE tasks SET state='completed',phase='duplicate',video_id=?,error=NULL,error_code=NULL WHERE id=? AND state='running' AND EXISTS(SELECT 1 FROM videos WHERE id=?)", duplicate.VideoID, id, duplicate.VideoID)
			if updateErr != nil {
				return true, updateErr
			}
			if count, _ := result.RowsAffected(); count == 1 {
				a.cleanupImport(id, kind)
			} else {
				_, updateErr = a.DB.Exec("UPDATE tasks SET state='queued',phase='queued' WHERE id=? AND state='running'", id)
				a.cleanupImport(id, kind)
			}
			return true, updateErr
		}
		state, phase, code := "failed", "failed", "processing_failed"
		message := e.Error()
		var nextAttempt int64
		var de *downloadError
		if errors.As(e, &de) {
			code = de.Code
			if de.Retryable && autoRetries < 2 {
				state, phase = "queued", "retry_wait"
				delay := 15 * time.Second
				if autoRetries > 0 {
					delay = 60 * time.Second
				}
				if de.RetryAfter > delay {
					delay = de.RetryAfter
				}
				nextAttempt = time.Now().Add(delay).Unix()
				autoRetries++
			}
		}
		if parentContext.Err() != nil {
			state, phase, code = "queued", "queued", "interrupted"
			message = "服务停止，任务等待恢复"
			nextAttempt = 0
		}
		_, err = a.DB.Exec("UPDATE tasks SET state=?,phase=?,error=?,error_code=?,next_attempt_at=?,auto_retries=? WHERE id=? AND state='running'", state, phase, message, code, nextAttempt, autoRetries, id)
		var savedState string
		if e := a.DB.QueryRow("SELECT state FROM tasks WHERE id=?", id).Scan(&savedState); e != nil {
			return true, e
		}
		if savedState == "cancelled" {
			a.cleanupImport(id, kind)
		}
		return true, err
	}
	// Post-commit cleanup must never roll back a completed video.
	if kind == "upload" {
		os.Remove(source)
	}
	os.RemoveAll(folder)
	return true, nil
}
