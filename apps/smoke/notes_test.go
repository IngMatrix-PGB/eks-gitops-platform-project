package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func fakeNotes(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/notes" {
			t.Errorf("notes called on %q, want /notes", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
}

func notesHandler(t *testing.T, notesURL string) http.Handler {
	t.Helper()
	c, err := loadConfig(func(k string) string {
		if k == "NOTES_URL" {
			return notesURL
		}
		return ""
	})
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	var ready atomic.Bool
	ready.Store(true)
	return newHandler(c, &ready)
}

func do(h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
	return rec
}

func TestNotesURLValidation(t *testing.T) {
	for _, bad := range []string{"ftp://x", "http://", "http://x/notes", "http://x?y=1", "http://u:p@x", "://"} {
		if _, err := parseNotesURL(bad); err == nil {
			t.Errorf("NOTES_URL %q accepted", bad)
		}
	}
	for _, good := range []string{"http://notes:8080", "http://notes.dev.svc:8080/"} {
		if _, err := parseNotesURL(good); err != nil {
			t.Errorf("NOTES_URL %q rejected: %v", good, err)
		}
	}
}

func TestNotesRoutesAbsentWithoutURL(t *testing.T) {
	h := notesHandler(t, "")
	if got := do(h, "GET", "/api/notes", "").Code; got != http.StatusNotFound {
		t.Errorf("GET /api/notes without NOTES_URL = %d, want 404", got)
	}
}

func TestNotesPassThrough(t *testing.T) {
	up := fakeNotes(t, http.StatusCreated, `{"id": 7}`)
	defer up.Close()
	h := notesHandler(t, up.URL)
	rec := do(h, "POST", "/api/notes", `{"body":"x"}`)
	if rec.Code != http.StatusCreated || !strings.Contains(rec.Body.String(), `"id": 7`) {
		t.Errorf("POST = %d %q", rec.Code, rec.Body.String())
	}
	bad := fakeNotes(t, http.StatusBadRequest, `{"error":"x"}`)
	defer bad.Close()
	if got := do(notesHandler(t, bad.URL), "POST", "/api/notes", `{}`).Code; got != http.StatusBadRequest {
		t.Errorf("notes 400 became %d", got)
	}
}

// notes' standard-library server reads only Content-Length: the proxy must
// forward the body with a length, never chunked.
func TestNotesForwardsBodyWithContentLength(t *testing.T) {
	var gotLen int64
	var gotBody string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotLen = r.ContentLength
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusCreated)
	}))
	defer up.Close()
	do(notesHandler(t, up.URL), "POST", "/api/notes", `{"body":"x"}`)
	if gotLen != int64(len(`{"body":"x"}`)) || gotBody != `{"body":"x"}` {
		t.Errorf("notes got Content-Length %d body %q, want %d and the same body", gotLen, gotBody, len(`{"body":"x"}`))
	}
}

func TestNotesFailuresBecome502(t *testing.T) {
	down := fakeNotes(t, http.StatusServiceUnavailable, `{"error":"db"}`)
	defer down.Close()
	if got := do(notesHandler(t, down.URL), "GET", "/api/notes", "").Code; got != http.StatusBadGateway {
		t.Errorf("notes 503 became %d, want 502", got)
	}
	closed := httptest.NewServer(http.NotFoundHandler())
	url := closed.URL
	closed.Close()
	if got := do(notesHandler(t, url), "GET", "/api/notes", "").Code; got != http.StatusBadGateway {
		t.Errorf("unreachable notes = %d, want 502", got)
	}
}

func TestNotesRequestBodyCapped(t *testing.T) {
	up := fakeNotes(t, http.StatusCreated, `{}`)
	defer up.Close()
	if got := do(notesHandler(t, up.URL), "POST", "/api/notes", strings.Repeat("x", notesMaxRequest+1)).Code; got != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized body = %d, want 413", got)
	}
}

func TestNotesRouteLabel(t *testing.T) {
	up := fakeNotes(t, http.StatusOK, `{"notes":[]}`)
	defer up.Close()
	m := newMetrics()
	h := m.instrument(notesHandler(t, up.URL))
	do(h, "GET", "/api/notes", "")
	var b strings.Builder
	m.write(&b)
	if !strings.Contains(b.String(), `http_requests_total{route="/api/notes",code="200"} 1`) {
		t.Errorf("metrics missing /api/notes:\n%s", b.String())
	}
}
