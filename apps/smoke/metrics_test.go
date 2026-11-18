package main

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func scrape(t *testing.T, m *metrics) string {
	t.Helper()
	rr := httptest.NewRecorder()
	m.handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("GET /metrics = %d", rr.Code)
	}
	if ct := rr.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain; version=0.0.4") {
		t.Fatalf("unexpected content type %q", ct)
	}
	return rr.Body.String()
}

func mustContain(t *testing.T, body string, lines ...string) {
	t.Helper()
	for _, l := range lines {
		if !strings.Contains(body, l+"\n") {
			t.Errorf("missing line %q in:\n%s", l, body)
		}
	}
}

// TestInstrumentCountsByRouteAndCode drives the real handler through the
// middleware and checks the exposition.
func TestInstrumentCountsByRouteAndCode(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	m := newMetrics()
	h := m.instrument(newHandler(config{uiMessage: "x"}, &ready))
	for _, path := range []string{"/", "/", "/api/info", "/healthz", "/nope", "/nope/deeper"} {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil))
	}
	ready.Store(false)
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/readyz", nil))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/api/info", nil))

	body := scrape(t, m)
	mustContain(t, body,
		`# TYPE http_requests_total counter`,
		`http_requests_total{route="/",code="200"} 2`,
		`http_requests_total{route="/api/info",code="200"} 1`,
		`http_requests_total{route="/healthz",code="200"} 1`,
		`http_requests_total{route="/readyz",code="503"} 1`,
		`http_requests_total{route="unmatched",code="404"} 2`,
		`http_requests_total{route="unmatched",code="405"} 1`,
		`# TYPE http_request_duration_seconds histogram`,
		`http_request_duration_seconds_bucket{route="/",le="+Inf"} 2`,
		`http_request_duration_seconds_count{route="/"} 2`,
		`smoke_build_info{version="dev"} 1`,
	)
	if strings.Contains(body, "/nope") {
		t.Error("a client-chosen path leaked into a label")
	}
}

func TestHistogramBucketsAreCumulative(t *testing.T) {
	m := newMetrics()
	m.observe("/", 200, 3*time.Millisecond)   // first bucket
	m.observe("/", 200, 100*time.Millisecond) // exactly on 0.1
	m.observe("/", 200, 7*time.Second)        // only +Inf
	mustContain(t, scrape(t, m),
		`http_request_duration_seconds_bucket{route="/",le="0.005"} 1`,
		`http_request_duration_seconds_bucket{route="/",le="0.05"} 1`,
		`http_request_duration_seconds_bucket{route="/",le="0.1"} 2`,
		`http_request_duration_seconds_bucket{route="/",le="5"} 2`,
		`http_request_duration_seconds_bucket{route="/",le="+Inf"} 3`,
		`http_request_duration_seconds_count{route="/"} 3`,
		`http_request_duration_seconds_sum{route="/"} 7.103`,
	)
}

func TestEscapeLabel(t *testing.T) {
	if got := escapeLabel("a\"b\\c\nd"); got != `a\"b\\c\nd` {
		t.Fatalf("escapeLabel = %q", got)
	}
}

// TestMetricsOnlyOnMetricsListener: /metrics is not served on the
// application port, and the application is not served on the metrics port.
func TestMetricsOnlyOnMetricsListener(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	mln, _ := net.Listen("tcp", "127.0.0.1:0")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, ln, mln, config{uiMessage: "x", shutdownTimeout: time.Second}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	}()
	defer func() { cancel(); <-done }()

	get := func(url string) (int, string) {
		deadline := time.Now().Add(2 * time.Second)
		for {
			resp, err := http.Get(url)
			if err == nil {
				b, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				return resp.StatusCode, string(b)
			}
			if time.Now().After(deadline) {
				t.Fatalf("GET %s: %v", url, err)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	app := "http://" + ln.Addr().String()
	met := "http://" + mln.Addr().String()
	if code, _ := get(app + "/metrics"); code != http.StatusNotFound {
		t.Errorf("GET /metrics on the application port = %d, want 404", code)
	}
	if code, _ := get(met + "/api/info"); code != http.StatusNotFound {
		t.Errorf("GET /api/info on the metrics port = %d, want 404", code)
	}
	get(app + "/api/info")
	code, body := get(met + "/metrics")
	if code != http.StatusOK || !strings.Contains(body, `http_requests_total{route="/api/info",code="200"} 1`) {
		t.Errorf("metrics port did not report the request: %d\n%s", code, body)
	}
}
