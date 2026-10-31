package family

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

func publicAddress(ip netip.Addr) bool {
	ip = ip.Unmap()
	return ip.IsValid() && ip.IsGlobalUnicast() && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() &&
		!netip.MustParsePrefix("100.64.0.0/10").Contains(ip) && !netip.MustParsePrefix("198.18.0.0/15").Contains(ip)
}

func newDownloadClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.ResponseHeaderTimeout = 20 * time.Second
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		if err != nil {
			return nil, err
		}
		var last error
		for _, ip := range ips {
			if !publicAddress(ip) {
				return nil, errors.New("视频源不是公网地址")
			}
		}
		for _, ip := range ips {
			conn, err := (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
			if err == nil {
				return conn, nil
			}
			last = err
		}
		if last == nil {
			last = errors.New("视频源域名没有可用地址")
		}
		return nil, last
	}
	return &http.Client{Transport: transport, CheckRedirect: func(r *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("视频源重定向次数过多")
		}
		return validateSource(r.URL)
	}}
}

func validateSource(u *url.URL) error {
	if u == nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil {
		return derror("invalid_source", "视频源地址格式无效", false)
	}
	return nil
}

func retryAfter(raw string) time.Duration {
	if n, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64); err == nil && n > 0 && n < 86400*30 {
		return time.Duration(n) * time.Second
	}
	if t, err := http.ParseTime(raw); err == nil && t.After(time.Now()) {
		return time.Until(t)
	}
	return 0
}

const maxVideoBytes int64 = 2 * 1024 * 1024 * 1024

func (a *App) transfer(ctx context.Context, raw string, headers map[string]string, target string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return derror("invalid_source", "视频源地址格式无效", false)
	}
	if err = validateSource(u); err != nil {
		return err
	}
	// Cancel a stalled body read instead of holding the single worker for the
	// whole task budget when a CDN stops sending bytes.
	stallCtx, stallCancel := context.WithCancel(ctx)
	defer stallCancel()
	req, _ := http.NewRequestWithContext(stallCtx, "GET", raw, nil)
	// Request only browser identity/origin metadata, never forward account cookies
	// to CDN hosts. Each attempt uses a newly resolved URL and starts at byte zero.
	for _, key := range []string{"User-Agent", "Referer"} {
		if value := headers[key]; len(value) <= 2048 && !strings.ContainsAny(value, "\r\n") {
			req.Header.Set(key, value)
		}
	}
	client := a.DownloadHTTP
	if client == nil {
		client = newDownloadClient()
	}
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return derror("media_network", "连接视频源失败，稍后自动重试", true)
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return derror("media_denied", "视频源暂时拒绝访问，将刷新地址并尝试其他源", true)
	}
	if resp.StatusCode == 429 {
		return &downloadError{Code: "rate_limited", Message: "视频源请求过于频繁，稍后自动重试", Retryable: true, RetryAfter: retryAfter(resp.Header.Get("Retry-After"))}
	}
	if resp.StatusCode >= 500 {
		return derror("media_unavailable", "视频源暂时不可用，稍后自动重试", true)
	}
	if resp.StatusCode != http.StatusOK {
		return derror("media_status", fmt.Sprintf("视频源返回异常状态 %d", resp.StatusCode), resp.StatusCode == 404 || resp.StatusCode == 410)
	}
	if resp.ContentLength > maxVideoBytes {
		return derror("too_large", "单个视频超过 2GB，暂不支持导入", false)
	}
	typeName := strings.ToLower(resp.Header.Get("Content-Type"))
	if strings.Contains(typeName, "text/html") || strings.Contains(typeName, "application/json") {
		return derror("invalid_media", "视频源返回了网页或验证信息，无法作为视频导入", false)
	}
	free, err := a.FreeSpace(a.Config.Data)
	if err != nil {
		return derror("storage", "无法检查磁盘空间", false)
	}
	required := uint64(1024 * 1024 * 1024)
	if resp.ContentLength > 0 && uint64(resp.ContentLength)*3 > required {
		required = uint64(resp.ContentLength) * 3
	}
	if free < required {
		return derror("storage", "磁盘剩余空间不足，请先清理视频库", false)
	}
	f, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return derror("storage", "无法创建视频文件，请检查磁盘与目录权限", false)
	}
	complete := false
	defer func() {
		f.Close()
		if !complete {
			os.Remove(target)
		}
	}()
	var received int64
	last := time.Now()
	a.progress(ctx, "downloading", 0, max(resp.ContentLength, 0))
	buffer := make([]byte, 128*1024)
	reader := io.LimitReader(resp.Body, maxVideoBytes+1)
	stall := time.AfterFunc(2*time.Minute, stallCancel)
	defer stall.Stop()
	for {
		n, readErr := reader.Read(buffer)
		stall.Reset(2 * time.Minute)
		if n > 0 {
			received += int64(n)
			if received > maxVideoBytes {
				return derror("too_large", "单个视频超过 2GB，暂不支持导入", false)
			}
			if _, err = f.Write(buffer[:n]); err != nil {
				return derror("storage", "写入视频失败，请检查剩余空间", false)
			}
			if time.Since(last) >= 500*time.Millisecond {
				a.progress(ctx, "downloading", received, max(resp.ContentLength, 0))
				last = time.Now()
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if stallCtx.Err() != nil {
				return derror("media_network", "视频源长时间没有数据，稍后自动重试", true)
			}
			return derror("media_incomplete", "视频传输中断，稍后重新获取完整文件", true)
		}
	}
	if received == 0 || (resp.ContentLength >= 0 && received != resp.ContentLength) {
		return derror("media_incomplete", "视频下载不完整，稍后自动重试", true)
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err = f.Close(); err != nil {
		return derror("storage", "保存视频失败，请检查磁盘空间", false)
	}
	complete = true
	a.progress(ctx, "downloading", received, received)
	return nil
}
