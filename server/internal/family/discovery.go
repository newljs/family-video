package family

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"regexp"
	"time"
)

const DiscoveryPort = 8766

var discoveryNonce = regexp.MustCompile(`^[a-f0-9]{32}$`)

type discoveryRequest struct {
	Service  string `json:"service"`
	Kind     string `json:"kind"`
	Protocol int    `json:"protocol"`
	Nonce    string `json:"nonce"`
}
type discoveryResponse struct {
	Service    string `json:"service"`
	Kind       string `json:"kind"`
	Protocol   int    `json:"protocol"`
	Nonce      string `json:"nonce"`
	InstanceID string `json:"instance_id"`
	Name       string `json:"name"`
	HTTPPort   int    `json:"http_port"`
	Version    string `json:"version"`
}

func discoveryReply(raw []byte, port int, instance, name string) ([]byte, error) {
	var request discoveryRequest
	if len(raw) > 512 || json.Unmarshal(raw, &request) != nil || request.Service != "family-video" ||
		request.Kind != "discover" || request.Protocol != 1 || !discoveryNonce.MatchString(request.Nonce) || port < 1 || port > 65535 {
		return nil, fmt.Errorf("invalid discovery request")
	}
	return json.Marshal(discoveryResponse{Service: "family-video", Kind: "server", Protocol: 1,
		Nonce: request.Nonce, InstanceID: instance, Name: clipped(name, 64), HTTPPort: port, Version: serverVersion})
}

// StartDiscovery runs beside HTTP, never in an API handler. Broadcasts carry no
// credentials; the client verifies /health before offering a server to the user.
func StartDiscovery(ctx context.Context, httpAddr *net.TCPAddr) (func(), error) {
	if httpAddr.IP.IsLoopback() {
		return func() {}, nil
	}
	ip := httpAddr.IP.To4()
	if ip == nil && !httpAddr.IP.IsUnspecified() {
		return nil, fmt.Errorf("局域网自动发现需要 IPv4 HTTP 监听地址")
	}
	if ip == nil {
		ip = net.IPv4zero
	}
	stop, _, err := listenDiscovery(ctx, httpAddr.Port, &net.UDPAddr{IP: ip, Port: DiscoveryPort})
	return stop, err
}

func listenDiscovery(ctx context.Context, httpPort int, bind *net.UDPAddr) (func(), *net.UDPAddr, error) {
	conn, err := net.ListenUDP("udp4", bind)
	if err != nil {
		return nil, nil, err
	}
	name, _ := os.Hostname()
	if name == "" {
		name = "家庭电脑"
	}
	instance := ID()
	addr := conn.LocalAddr().(*net.UDPAddr)
	done := make(chan struct{})
	cancelClose := context.AfterFunc(ctx, func() { conn.Close() })
	go func() {
		defer close(done)
		defer conn.Close()
		defer cancelClose()
		last := map[string]time.Time{}
		buffer := make([]byte, 513)
		for {
			n, peer, err := conn.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			if !peer.IP.IsPrivate() && !peer.IP.IsLoopback() && !peer.IP.IsLinkLocalUnicast() {
				continue
			}
			raw, err := discoveryReply(buffer[:n], httpPort, instance, name)
			if err != nil {
				continue
			}
			key := peer.IP.String()
			now := time.Now()
			if now.Sub(last[key]) < 200*time.Millisecond {
				continue
			}
			if len(last) >= 256 {
				clear(last)
			}
			last[key] = now
			conn.WriteToUDP(raw, peer)
		}
	}()
	return func() { conn.Close(); <-done }, addr, nil
}
