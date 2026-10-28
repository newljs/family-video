package family

import (
	"archive/zip"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

type backupFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size_bytes"`
	SHA256 string `json:"sha256"`
}
type backupManifest struct {
	Format  int          `json:"format"`
	Created string       `json:"created_at"`
	Files   []backupFile `json:"files"`
}

func snapshotDB(db *sql.DB, target string) error {
	if _, err := db.Exec("VACUUM INTO ?", target); err != nil {
		return err
	}
	return nil
}

func readOnlyDB(file string) (*sql.DB, error) {
	// Snapshot paths are generated locally, not URI parameters from the network.
	db, err := sql.Open("sqlite", filepath.ToSlash(file))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err = db.Exec("PRAGMA query_only=ON"); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

// Daily snapshots are small database + media inventories; full backups use the
// offline command so copying large media never races with imports or deletion.
func (a *App) dailySnapshot() error {
	root := filepath.Join(a.Config.Data, "backups", "database")
	if err := os.MkdirAll(root, 0700); err != nil {
		return err
	}
	target := filepath.Join(root, today()+".sqlite3")
	if _, err := os.Stat(target); err == nil {
		return nil
	}
	tmp := filepath.Join(root, ID()+".tmp")
	defer os.Remove(tmp)
	if err := snapshotDB(a.DB, tmp); err != nil {
		return err
	}
	db, err := readOnlyDB(tmp)
	if err != nil {
		return err
	}
	items, err := query(db, "SELECT id,path,stream_state FROM videos ORDER BY id")
	db.Close()
	if err != nil {
		return err
	}
	raw, err := json.MarshalIndent(map[string]any{"created_at": time.Now().UTC().Format(time.RFC3339), "videos": items}, "", "  ")
	if err != nil {
		return err
	}
	if err = os.WriteFile(target+".media.json", raw, 0600); err != nil {
		return err
	}
	if err = os.Rename(tmp, target); err != nil {
		return err
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	cutoff := time.Now().AddDate(0, 0, -14).Format("2006-01-02")
	for _, entry := range entries {
		name := entry.Name()
		if len(name) == len("2006-01-02.sqlite3") && strings.HasSuffix(name, ".sqlite3") {
			if _, err := time.Parse("2006-01-02", strings.TrimSuffix(name, ".sqlite3")); err == nil && name[:10] < cutoff {
				if err = os.Remove(filepath.Join(root, name)); err != nil {
					return err
				}
				os.Remove(filepath.Join(root, name+".media.json"))
			}
		}
	}
	return nil
}

func backupPath(name string) bool {
	if name == "database/family.sqlite3" {
		return true
	}
	if name != path.Clean(name) || strings.ContainsAny(name, "\\:") || strings.HasPrefix(name, "/") {
		return false
	}
	for _, prefix := range []string{"videos/", "thumbnails/", "streams/"} {
		if strings.HasPrefix(name, prefix) && len(name) > len(prefix) {
			return true
		}
	}
	return false
}

func CreateBackup(a *App, output string) (err error) {
	snapshot := filepath.Join(a.Config.Data, "database", ID()+".backup.tmp")
	defer os.Remove(snapshot)
	if err = snapshotDB(a.DB, snapshot); err != nil {
		return err
	}
	db, err := readOnlyDB(snapshot)
	if err != nil {
		return err
	}
	items, err := query(db, "SELECT id,path,stream_state FROM videos ORDER BY id")
	db.Close()
	if err != nil {
		return err
	}
	sources := map[string]string{"database/family.sqlite3": snapshot}
	for _, item := range items {
		id, name := item["id"].(string), item["path"].(string)
		if !safeVideoID.MatchString(id) || filepath.Base(name) != name {
			return fmt.Errorf("视频路径无效")
		}
		sources["videos/"+name] = filepath.Join(a.Config.Data, "videos", name)
		cover := filepath.Join(a.Config.Data, "thumbnails", id+".jpg")
		if _, e := os.Stat(cover); e == nil {
			sources["thumbnails/"+id+".jpg"] = cover
		}
		stream := filepath.Join(a.Config.Data, "streams", id)
		if _, e := os.Stat(stream); e == nil {
			if err = filepath.WalkDir(stream, func(file string, entry os.DirEntry, e error) error {
				if e != nil {
					return e
				}
				if entry.IsDir() {
					return nil
				}
				rel, e := filepath.Rel(a.Config.Data, file)
				if e != nil {
					return e
				}
				sources[filepath.ToSlash(rel)] = file
				return nil
			}); err != nil {
				return err
			}
		}
	}
	out, err := os.OpenFile(output, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer func() {
		out.Close()
		if err != nil {
			os.Remove(output)
		}
	}()
	archive := zip.NewWriter(out)
	manifest := backupManifest{Format: 1, Created: time.Now().UTC().Format(time.RFC3339), Files: []backupFile{}}
	for name, source := range sources {
		if !backupPath(name) {
			return fmt.Errorf("备份路径无效")
		}
		info, e := os.Lstat(source)
		if e != nil {
			return e
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("备份仅支持常规文件")
		}
		input, e := os.Open(source)
		if e != nil {
			return e
		}
		entry, e := archive.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Store})
		if e != nil {
			input.Close()
			return e
		}
		hash := sha256.New()
		size, e := io.Copy(io.MultiWriter(entry, hash), input)
		input.Close()
		if e != nil {
			return e
		}
		manifest.Files = append(manifest.Files, backupFile{Path: name, Size: size, SHA256: hex.EncodeToString(hash.Sum(nil))})
	}
	entry, err := archive.Create("manifest.json")
	if err != nil {
		return err
	}
	if err = json.NewEncoder(entry).Encode(manifest); err != nil {
		return err
	}
	if err = archive.Close(); err != nil {
		return err
	}
	return out.Sync()
}

func checkedBackup(input string) (*zip.ReadCloser, backupManifest, error) {
	var manifest backupManifest
	archive, err := zip.OpenReader(input)
	if err != nil {
		return nil, manifest, err
	}
	bad := func(e error) (*zip.ReadCloser, backupManifest, error) { archive.Close(); return nil, manifest, e }
	entries := map[string]*zip.File{}
	for _, file := range archive.File {
		if entries[file.Name] != nil || file.Mode()&os.ModeSymlink != 0 {
			return bad(fmt.Errorf("备份含重复或符号链接条目"))
		}
		entries[file.Name] = file
	}
	meta := entries["manifest.json"]
	if meta == nil || meta.UncompressedSize64 > 16*1024*1024 {
		return bad(fmt.Errorf("备份清单缺失或过大"))
	}
	reader, err := meta.Open()
	if err != nil {
		return bad(err)
	}
	err = json.NewDecoder(io.LimitReader(reader, 16*1024*1024)).Decode(&manifest)
	reader.Close()
	if err != nil {
		return bad(err)
	}
	if manifest.Format != 1 || len(entries) != len(manifest.Files)+1 {
		return bad(fmt.Errorf("不支持的备份格式或条目数量"))
	}
	seen := map[string]bool{}
	for _, file := range manifest.Files {
		entry := entries[file.Path]
		if !backupPath(file.Path) || seen[file.Path] || entry == nil || file.Size < 0 || entry.UncompressedSize64 != uint64(file.Size) {
			return bad(fmt.Errorf("备份条目无效: %s", file.Path))
		}
		seen[file.Path] = true
		source, e := entry.Open()
		if e != nil {
			return bad(e)
		}
		hash := sha256.New()
		size, e := io.Copy(hash, source)
		source.Close()
		if e != nil || size != file.Size || hex.EncodeToString(hash.Sum(nil)) != file.SHA256 {
			return bad(fmt.Errorf("备份校验失败: %s", file.Path))
		}
	}
	if !seen["database/family.sqlite3"] {
		return bad(fmt.Errorf("备份缺少数据库"))
	}
	return archive, manifest, nil
}

func VerifyBackup(input string) error {
	archive, _, err := checkedBackup(input)
	if err == nil {
		archive.Close()
	}
	return err
}

// Restore always targets a NEW directory, leaving the current library intact.
func RestoreBackup(input, target string) (err error) {
	archive, manifest, err := checkedBackup(input)
	if err != nil {
		return err
	}
	defer archive.Close()
	target, err = filepath.Abs(target)
	if err != nil {
		return err
	}
	if err = os.Mkdir(target, 0700); err != nil {
		return fmt.Errorf("恢复目录必须尚不存在: %w", err)
	}
	defer func() {
		if err != nil {
			os.RemoveAll(target)
		}
	}()
	entries := map[string]*zip.File{}
	for _, file := range archive.File {
		entries[file.Name] = file
	}
	for _, file := range manifest.Files {
		dest := filepath.Join(target, filepath.FromSlash(file.Path))
		if err = os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
			return err
		}
		source, e := entries[file.Path].Open()
		if e != nil {
			return e
		}
		output, e := os.OpenFile(dest, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if e != nil {
			source.Close()
			return e
		}
		_, e = io.Copy(output, source)
		source.Close()
		closeErr := output.Close()
		if e != nil {
			return e
		}
		if closeErr != nil {
			return closeErr
		}
	}
	config, err := InitConfig(Config{Data: target})
	if err != nil {
		return err
	}
	app, err := New(config)
	if err != nil {
		return err
	}
	defer app.DB.Close()
	var check string
	if err = app.DB.QueryRow("PRAGMA quick_check").Scan(&check); err != nil {
		return err
	}
	if check != "ok" {
		return fmt.Errorf("恢复数据库检查失败")
	}
	broken, err := query(app.DB, "PRAGMA foreign_key_check")
	if err != nil {
		return err
	}
	if len(broken) > 0 {
		return fmt.Errorf("恢复数据库关联检查失败")
	}
	videos, err := query(app.DB, "SELECT id,path FROM videos")
	if err != nil {
		return err
	}
	for _, video := range videos {
		name := video["path"].(string)
		if filepath.Base(name) != name {
			return fmt.Errorf("恢复视频路径无效")
		}
		if _, err = os.Stat(filepath.Join(target, "videos", name)); err != nil {
			return fmt.Errorf("恢复缺少视频文件: %s", name)
		}
	}
	_, err = app.DB.Exec("UPDATE tasks SET state='failed',phase='failed',error='备份不含导入临时文件，请重新导入',error_code='restore_requires_import' WHERE state IN ('queued','running')")
	return err
}

type OrphanFile struct {
	Path string `json:"path"`
	Size int64  `json:"size_bytes"`
}

func ScanOrphans(a *App, apply bool) ([]OrphanFile, error) {
	items, err := query(a.DB, "SELECT id,path FROM videos")
	if err != nil {
		return nil, err
	}
	keep := map[string]bool{}
	for _, item := range items {
		id, name := item["id"].(string), item["path"].(string)
		keep["videos/"+name], keep["thumbnails/"+id+".jpg"], keep["streams/"+id] = true, true, true
	}
	candidates := []OrphanFile{}
	for _, dir := range []string{"videos", "thumbnails", "streams"} {
		root := filepath.Join(a.Config.Data, dir)
		err = filepath.WalkDir(root, func(file string, entry os.DirEntry, e error) error {
			if e != nil {
				return e
			}
			if entry.IsDir() {
				return nil
			}
			rel, e := filepath.Rel(a.Config.Data, file)
			if e != nil {
				return e
			}
			name := filepath.ToSlash(rel)
			if dir == "streams" {
				parts := strings.Split(name, "/")
				if len(parts) > 1 && keep["streams/"+parts[1]] {
					return nil
				}
			}
			if keep[name] {
				return nil
			}
			info, e := entry.Info()
			if e != nil {
				return e
			}
			if !info.Mode().IsRegular() || time.Since(info.ModTime()) < 24*time.Hour {
				return nil
			}
			candidates = append(candidates, OrphanFile{Path: name, Size: info.Size()})
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	if apply && len(candidates) > 0 {
		quarantine := filepath.Join(a.Config.Data, "quarantine", time.Now().UTC().Format("20060102-150405")+"-"+ID()[:8])
		if err = os.MkdirAll(quarantine, 0700); err != nil {
			return nil, err
		}
		raw, _ := json.MarshalIndent(candidates, "", "  ")
		if err = os.WriteFile(filepath.Join(quarantine, "manifest.json"), raw, 0600); err != nil {
			return nil, err
		}
		for _, file := range candidates {
			dest := filepath.Join(quarantine, filepath.FromSlash(file.Path))
			if err = os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
				return nil, err
			}
			if err = os.Rename(filepath.Join(a.Config.Data, filepath.FromSlash(file.Path)), dest); err != nil {
				return nil, err
			}
		}
	}
	return candidates, nil
}
