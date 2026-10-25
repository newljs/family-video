package family

import (
	"strings"
	"testing"
)

func TestQrcodeEndpoint(t *testing.T) {
	a := testApp(t)
	w := request(t, a, "GET", "/qrcode?text=http%3A%2F%2F192.168.1.10%3A8765", "parent", nil)
	if w.Code != 200 {
		t.Fatalf("qrcode status %d", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "image/png" {
		t.Fatalf("Content-Type = %q", ct)
	}
	if !strings.HasPrefix(w.Body.String(), "\x89PNG") {
		t.Fatal("response is not a PNG image")
	}
	// 非法协议与超长内容拒绝。
	if w := request(t, a, "GET", "/qrcode?text=javascript%3Aalert(1)", "parent", nil); w.Code != 400 {
		t.Fatalf("non-http scheme should 400, got %d", w.Code)
	}
	long := "http://example.com/" + strings.Repeat("a", 600)
	if w := request(t, a, "GET", "/qrcode?text="+long, "parent", nil); w.Code != 400 {
		t.Fatalf("oversized text should 400, got %d", w.Code)
	}
}

func TestServerAddresses(t *testing.T) {
	a := testApp(t)
	meta := object(t, request(t, a, "GET", "/api/server-addresses", "parent", nil))
	if _, ok := meta["addresses"].([]any); !ok {
		t.Fatalf("addresses should be an array: %v", meta)
	}
}
