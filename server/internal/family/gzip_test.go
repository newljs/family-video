package family

import (
	"compress/gzip"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGzipJSONResponses(t *testing.T) {
	a := testApp(t)
	seed(t, a, "gzip-video", true)
	r := httptest.NewRequest(http.MethodGet, "/api/videos", nil)
	r.Header.Set("Accept-Encoding", "gzip")
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	if got := w.Header().Get("Content-Encoding"); got != "gzip" {
		t.Fatalf("Content-Encoding = %q", got)
	}
	zr, err := gzip.NewReader(w.Body)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	var items []map[string]any
	if err = json.NewDecoder(zr).Decode(&items); err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("items = %d", len(items))
	}
}

func TestGzipJSONSkipsAPKDownload(t *testing.T) {
	a := testApp(t)
	r := httptest.NewRequest(http.MethodGet, "/api/apps/kids/download", nil)
	r.Header.Set("Accept-Encoding", "gzip")
	w := httptest.NewRecorder()
	a.Handler().ServeHTTP(w, r)
	if got := w.Header().Get("Content-Encoding"); got != "" {
		t.Fatalf("download must not be gzipped, got %q", got)
	}
}
