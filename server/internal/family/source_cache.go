package family

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const cacheFileLimit int64 = 256 * 1024 * 1024
const cacheTotalLimit int64 = 512 * 1024 * 1024
const cacheLifetime = 24 * time.Hour

type sourceManifest struct {
	Digest   string        `json:"sha256"`
	Metadata videoMetadata `json:"metadata"`
	Size     int64         `json:"size"`
	Created  int64         `json:"created"`
}

func sourceKey(source string) string {
	h := sha256.Sum256([]byte(source))
	return hex.EncodeToString(h[:])
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}

func (a *App) cachedSource(ctx context.Context, source, folder string) (string, bool) {
	a.cacheMu.Lock()
	defer a.cacheMu.Unlock()
	root := filepath.Join(a.Config.Data, "download-cache")
	key := sourceKey(source)
	raw, err := os.ReadFile(filepath.Join(root, key+".json"))
	if err != nil {
		return "", false
	}
	var m sourceManifest
	if json.Unmarshal(raw, &m) != nil || m.Size <= 0 || m.Size > cacheFileLimit || time.Since(time.Unix(m.Created, 0)) > cacheLifetime {
		os.Remove(filepath.Join(root, key+".json"))
		os.Remove(filepath.Join(root, key+".mp4"))
		return "", false
	}
	f, err := os.Open(filepath.Join(root, key+".mp4"))
	if err != nil {
		return "", false
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, contextReader{ctx, f})
	if err != nil || n != m.Size || hex.EncodeToString(h.Sum(nil)) != m.Digest {
		return "", false
	}
	if _, err = f.Seek(0, 0); err != nil {
		return "", false
	}
	target := filepath.Join(folder, "source.mp4")
	tmp := target + ".part"
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return "", false
	}
	_, err = io.Copy(out, contextReader{ctx, f})
	closeErr := out.Close()
	if err != nil || closeErr != nil || ctx.Err() != nil {
		os.Remove(tmp)
		return "", false
	}
	os.Remove(target)
	if os.Rename(tmp, target) != nil {
		os.Remove(tmp)
		return "", false
	}
	writeMetadata(folder, m.Metadata)
	a.progress(ctx, "cached", m.Size, m.Size)
	return target, true
}

func (a *App) cacheSource(ctx context.Context, source, path string) {
	info, err := os.Stat(path)
	if err != nil || info.Size() > cacheFileLimit || info.Size() == 0 || ctx.Err() != nil {
		return
	}
	free, err := a.FreeSpace(a.Config.Data)
	if err != nil || free < uint64(info.Size()*4)+1024*1024*1024 {
		return
	}
	a.cacheMu.Lock()
	defer a.cacheMu.Unlock()
	root := filepath.Join(a.Config.Data, "download-cache")
	if os.MkdirAll(root, 0700) != nil {
		return
	}
	tmp := filepath.Join(root, ID()+".tmp")
	defer os.Remove(tmp)
	src, err := os.Open(path)
	if err != nil {
		return
	}
	defer src.Close()
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return
	}
	h := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(out, h), contextReader{ctx, src})
	closeErr := out.Close()
	if copyErr != nil || closeErr != nil || n != info.Size() || ctx.Err() != nil {
		return
	}
	key := sourceKey(source)
	target := filepath.Join(root, key+".mp4")
	os.Remove(target)
	if os.Rename(tmp, target) != nil {
		return
	}
	m := sourceManifest{Digest: hex.EncodeToString(h.Sum(nil)), Size: n, Created: time.Now().Unix(), Metadata: readMetadata(filepath.Dir(path))}
	raw, _ := json.Marshal(m)
	if os.WriteFile(filepath.Join(root, key+".json"), raw, 0600) != nil {
		os.Remove(target)
		return
	}
	a.pruneSources(root)
}

func (a *App) pruneSources(root string) {
	entries, _ := os.ReadDir(root)
	type item struct {
		key string
		m   sourceManifest
	}
	var items []item
	var total int64
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		key := strings.TrimSuffix(e.Name(), ".json")
		if len(key) != 64 {
			continue
		}
		if _, err := hex.DecodeString(key); err != nil {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(root, e.Name()))
		var m sourceManifest
		if err != nil || json.Unmarshal(raw, &m) != nil {
			continue
		}
		if time.Since(time.Unix(m.Created, 0)) > cacheLifetime {
			os.Remove(filepath.Join(root, key+".mp4"))
			os.Remove(filepath.Join(root, key+".json"))
			continue
		}
		items = append(items, item{key, m})
		total += m.Size
	}
	sort.Slice(items, func(i, j int) bool { return items[i].m.Created < items[j].m.Created })
	for _, entry := range items {
		if total <= cacheTotalLimit {
			break
		}
		os.Remove(filepath.Join(root, entry.key+".mp4"))
		os.Remove(filepath.Join(root, entry.key+".json"))
		total -= entry.m.Size
	}
}
