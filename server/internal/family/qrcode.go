package family

// 手机连接支持：枚举本机局域网地址并生成二维码 PNG，
// 手机扫码即可获得服务器地址或直接下载客户端安装包。

import (
	"net"
	"net/http"
	"strings"

	qrcode "github.com/skip2/go-qrcode"
)

// lanAddresses 返回本机所有已启用的非回环 IPv4 地址（含端口）。
func (a *App) lanAddresses() []string {
	found := []string{}
	seen := map[string]bool{}
	interfaces, err := net.Interfaces()
	if err != nil {
		return found
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addresses {
			ipnet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipnet.IP.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
				continue
			}
			hostport := net.JoinHostPort(ip4.String(), a.Config.Port)
			if !seen[hostport] {
				seen[hostport] = true
				found = append(found, hostport)
			}
		}
	}
	return found
}

func (a *App) serverAddresses(w http.ResponseWriter, r *http.Request, _ string) error {
	reply(w, 200, map[string]any{"addresses": a.lanAddresses()})
	return nil
}

// qrcodePNG 把 http/https 链接渲染为二维码图片；限制协议防止被当作任意内容通道。
func (a *App) qrcodePNG(w http.ResponseWriter, r *http.Request, _ string) error {
	text := r.URL.Query().Get("text")
	if len(text) > 512 ||
		(!strings.HasPrefix(text, "http://") && !strings.HasPrefix(text, "https://")) {
		return fail(400, "仅支持生成 http/https 链接的二维码")
	}
	png, err := qrcode.Encode(text, qrcode.Medium, 240)
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(png)
	return nil
}
