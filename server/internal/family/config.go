package family

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Config struct{ Root, Data, F2Exe, F2Config, Host, Port, SigningKey, ResolverPython string }

func ID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func LoadConfig() (Config, error) {
	root, _ := os.Getwd()
	for p := root; ; p = filepath.Dir(p) {
		if _, err := os.Stat(filepath.Join(p, "apps", "kids_app")); err == nil {
			root = p
			break
		}
		if filepath.Dir(p) == p {
			break
		}
	}
	if f, err := os.Open(filepath.Join(root, ".env")); err == nil {
		defer f.Close()
		scan := bufio.NewScanner(f)
		for scan.Scan() {
			line := strings.TrimSpace(scan.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			k, v, ok := strings.Cut(line, "=")
			if ok {
				k = strings.TrimSpace(k)
				if _, set := os.LookupEnv(k); !set {
					os.Setenv(k, strings.Trim(strings.TrimSpace(v), "\"'"))
				}
			}
		}
	}
	env := func(k, d string) string {
		if v := os.Getenv(k); v != "" {
			return v
		}
		return d
	}
	data := env("FAMILY_DATA_DIR", "runtime")
	if !filepath.IsAbs(data) {
		data = filepath.Join(root, data)
	}
	c := Config{Root: root, Data: data, F2Exe: env("FAMILY_F2_EXE", filepath.Join(root, ".downloader-venv", "Scripts", "f2.exe")), F2Config: env("FAMILY_F2_CONFIG", ""), ResolverPython: env("FAMILY_DOWNLOADER_PYTHON", ""), Host: env("FAMILY_HOST", "0.0.0.0"), Port: env("FAMILY_PORT", "8765")}
	return InitConfig(c)
}

func InitConfig(c Config) (Config, error) {
	for _, d := range []string{"database", "videos", "thumbnails", "temp", "streams"} {
		if err := os.MkdirAll(filepath.Join(c.Data, d), 0700); err != nil {
			return c, err
		}
	}
	path := filepath.Join(c.Data, "credentials.json")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err == nil {
		err = json.NewEncoder(f).Encode(map[string]string{"signing_key": ID() + ID()})
		f.Close()
		if err != nil {
			return c, err
		}
	} else if !os.IsExist(err) {
		return c, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	var keys map[string]string
	if err = json.Unmarshal(raw, &keys); err != nil {
		return c, err
	}
	c.SigningKey = keys["signing_key"]
	if c.SigningKey == "" {
		return c, fmt.Errorf("credentials.json 缺少内部媒体签名参数")
	}
	return c, nil
}
