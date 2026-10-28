package family

import (
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"
)

func TestDiscoveryProtocol(t *testing.T) {
	nonce := strings.Repeat("a", 32)
	request := `{"service":"family-video","kind":"discover","protocol":1,"nonce":"` + nonce + `"}`
	raw, err := discoveryReply([]byte(request), 9999, "instance", "computer")
	if err != nil {
		t.Fatal(err)
	}
	var response discoveryResponse
	if err = json.Unmarshal(raw, &response); err != nil {
		t.Fatal(err)
	}
	if response.Nonce != nonce || response.HTTPPort != 9999 || response.Kind != "server" || response.Name != "computer" {
		t.Fatal(response)
	}
	for _, bad := range []string{`{}`, strings.Replace(request, "discover", "server", 1), strings.Replace(request, nonce, "wrong", 1), strings.Repeat("x", 513), strings.Replace(request, `"protocol":1`, `"protocol":2`, 1)} {
		if _, err = discoveryReply([]byte(bad), 8765, "id", "name"); err == nil {
			t.Fatalf("accepted %s", bad)
		}
	}
}

func TestDiscoveryUDPAndCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stop, addr, err := listenDiscovery(ctx, 9876, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.DialUDP("udp4", nil, addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	nonce := strings.Repeat("b", 32)
	_, err = conn.Write([]byte(`{"service":"family-video","kind":"discover","protocol":1,"nonce":"` + nonce + `"}`))
	if err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 1024)
	n, err := conn.Read(buffer)
	if err != nil {
		t.Fatal(err)
	}
	var response discoveryResponse
	if err = json.Unmarshal(buffer[:n], &response); err != nil {
		t.Fatal(err)
	}
	if response.HTTPPort != 9876 || response.Nonce != nonce || response.InstanceID == "" {
		t.Fatal(response)
	}
	cancel()
	stopped := make(chan struct{})
	go func() { stop(); close(stopped) }()
	select {
	case <-stopped:
	case <-time.After(2 * time.Second):
		t.Fatal("discovery didn't stop")
	}
}
