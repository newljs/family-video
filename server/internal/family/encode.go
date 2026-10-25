package family

import (
	"context"
	"fmt"
	"log"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// hardwareEncoders lists candidates in preference order. Presence in
// `ffmpeg -encoders` only proves compile-time support; a missing GPU or driver
// surfaces at first use, and encodeVideo then falls back to libx264 and stops
// retrying the hardware encoder for later tasks.
var hardwareEncoders = []string{"h264_videotoolbox", "h264_nvenc", "h264_qsv", "h264_amf"}

type encoderCache struct {
	mu       sync.Mutex
	probed   bool
	name     string
	disabled bool
}

func (c *encoderCache) get(ctx context.Context, probe func(context.Context) string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.disabled {
		return ""
	}
	if !c.probed {
		c.name, c.probed = probe(ctx), true
	}
	return c.name
}

func (c *encoderCache) disable() {
	c.mu.Lock()
	c.disabled = true
	c.mu.Unlock()
}

func probeHWEncoder(ctx context.Context) string {
	raw, err := command(ctx, 10*time.Second, "ffmpeg", "-hide_banner", "-encoders")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		for _, name := range hardwareEncoders {
			if fields[1] == name {
				return name
			}
		}
	}
	return ""
}

// 4K/1440p 源按像素量拖慢重编码数倍，输出长边压到 1080p 档；可直拷贝的源保持原样。
const maxTranscodeEdge = 1920
const transcodeScaleFilter = "scale=w=1920:h=1920:force_original_aspect_ratio=decrease:force_divisible_by=2"

// encodeVideo re-encodes one source to H.264/AAC MP4, trying the hardware
// encoder first and libx264 second. width/height describe the source; oversized
// sources are downscaled to the 1080p tier while encoding.
func (a *App) encodeVideo(ctx context.Context, path, target string, width, height int) error {
	filter := ""
	var size [2]int
	if width > maxTranscodeEdge || height > maxTranscodeEdge {
		filter = transcodeScaleFilter
		size[0], size[1] = scaledSize(width, height)
	} else {
		size[0], size[1] = width, height
	}
	plans := a.encodePlans(ctx, size[0], size[1])
	for i, plan := range plans {
		args := append([]string{"-v", "error", "-y", "-i", path, "-map", "0:v:0", "-map", "0:a:0?"}, plan...)
		if filter != "" {
			args = append(args, "-vf", filter)
		}
		args = append(args, "-movflags", "+faststart", target)
		if _, err := command(ctx, 15*time.Minute, "ffmpeg", args...); err == nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if i == 0 && len(plans) > 1 {
			a.enc.disable()
			log.Printf("worker: 硬件编码器 %s 启动失败，本次及后续任务改用 libx264", plans[0][1])
		}
	}
	return fmt.Errorf("视频处理失败，请检查 FFmpeg 与磁盘空间")
}

// encodePlans returns codec argument sets: the probed hardware encoder first
// (if any), libx264 last as the always-working baseline.
func (a *App) encodePlans(ctx context.Context, width, height int) [][]string {
	probe := a.HWEncoderProbe
	if probe == nil {
		probe = probeHWEncoder
	}
	var plans [][]string
	if enc := a.enc.get(ctx, probe); enc != "" {
		plans = append(plans, []string{"-c:v", enc, "-b:v", videoBitrate(width, height), "-pix_fmt", "yuv420p", "-c:a", "aac"})
	}
	plans = append(plans, []string{"-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-threads", strconv.Itoa(encodeThreads()), "-pix_fmt", "yuv420p", "-c:a", "aac"})
	return plans
}

// 硬件编码器没有 CRF 质量档，统一按输出分辨率给目标码率。
func videoBitrate(width, height int) string {
	switch pixels := width * height; {
	case pixels > 1280*720:
		return "5000k"
	case pixels > 854*480:
		return "2500k"
	default:
		return "1200k"
	}
}

func scaledSize(width, height int) (int, int) {
	if width > maxTranscodeEdge && width >= height {
		width, height = maxTranscodeEdge, height*maxTranscodeEdge/width
	} else if height > maxTranscodeEdge {
		width, height = width*maxTranscodeEdge/height, maxTranscodeEdge
	}
	if width%2 == 1 {
		width--
	}
	if height%2 == 1 {
		height--
	}
	return width, height
}

// 软编码只占一半核心，导入不挤占家庭电脑的日常使用。
func encodeThreads() int {
	n := runtime.NumCPU() / 2
	if n < 2 {
		n = 2
	}
	if n > 8 {
		n = 8
	}
	return n
}
