package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadConfigDefaults(t *testing.T) {
	c, err := loadConfig(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if c.port != 9898 || c.uiMessage != "smoke" || c.shutdownTimeout != 5*time.Second {
		t.Fatalf("unexpected defaults: %+v", c)
	}
}

func TestLoadConfigPrecedenceAndFallback(t *testing.T) {
	c, err := loadConfig(env(map[string]string{
		"PODINFO_UI_MESSAGE":              "legacy",
		"PODINFO_SERVER_SHUTDOWN_TIMEOUT": "7s",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if c.uiMessage != "legacy" || c.shutdownTimeout != 7*time.Second {
		t.Fatalf("podinfo-era names not honored: %+v", c)
	}
	c, err = loadConfig(env(map[string]string{"UI_MESSAGE": "new", "PODINFO_UI_MESSAGE": "legacy"}))
	if err != nil || c.uiMessage != "new" {
		t.Fatalf("UI_MESSAGE must win over PODINFO_UI_MESSAGE: %+v %v", c, err)
	}
}

func TestLoadConfigRejectsInvalid(t *testing.T) {
	for _, m := range []map[string]string{
		{"PORT": "0"},
		{"PORT": "abc"},
		{"PORT": "70000"},
		{"SHUTDOWN_TIMEOUT": "forever"},
		{"SHUTDOWN_TIMEOUT": "-1s"},
		{"SHUTDOWN_TIMEOUT": "2m"},
	} {
		if _, err := loadConfig(env(m)); err == nil {
			t.Errorf("accepted invalid config %v", m)
		}
	}
}

func TestHandlerEndpoints(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	h := newHandler(config{uiMessage: "hello"}, &ready)

	for path, want := range map[string]int{"/healthz": 200, "/readyz": 200, "/": 200, "/nope": 404} {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
		if rr.Code != want {
			t.Errorf("GET %s = %d, want %d", path, rr.Code, want)
		}
	}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/", nil))
	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil || body["message"] != "hello" {
		t.Errorf("unexpected / body %q (%v)", rr.Body.String(), err)
	}

	ready.Store(false)
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusServiceUnavailable {
		t.Errorf("readyz after shutdown = %d, want 503", rr.Code)
	}
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rr.Code != http.StatusOK {
		t.Errorf("healthz must stay 200 while draining, got %d", rr.Code)
	}
}

// TestGracefulShutdownDrains proves an in-flight request completes after
// the shutdown signal, and that run returns cleanly within the timeout.
func TestGracefulShutdownDrains(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	c := config{uiMessage: "x", shutdownTimeout: 2 * time.Second}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- run(ctx, ln, c, slog.New(slog.NewTextHandler(io.Discard, nil))) }()

	url := "http://" + ln.Addr().String()
	deadline := time.Now().Add(2 * time.Second)
	for {
		resp, err := http.Get(url + "/healthz")
		if err == nil {
			resp.Body.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("server did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run returned %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("run did not return within the shutdown timeout")
	}
	if _, err := http.Get(url + "/healthz"); err == nil {
		t.Fatal("server still accepting connections after shutdown")
	}
}
