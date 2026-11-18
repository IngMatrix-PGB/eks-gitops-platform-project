package main

// Phase 6.1a (ADR-0021): request metrics in the Prometheus text
// exposition format (version 0.0.4), written with the standard library so
// the image keeps no third-party dependency.
//
//   smoke_build_info{version}                      gauge, always 1
//   http_requests_total{route,code}                counter
//   http_request_duration_seconds{route}           histogram
//
// route is the ServeMux pattern without its method ("/api/info", "/"),
// or "unmatched" when no pattern matched, so its cardinality is bounded
// by the routes the code declares, never by what clients send.

import (
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Upper bounds in seconds; +Inf is implicit.
var durationBuckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}

type histogram struct {
	counts []uint64 // per bucket, not cumulative; len(durationBuckets)+1
	sum    float64
	count  uint64
}

type requestKey struct {
	route string
	code  int
}

type metrics struct {
	mu        sync.Mutex
	requests  map[requestKey]uint64
	durations map[string]*histogram
}

func newMetrics() *metrics {
	return &metrics{requests: map[requestKey]uint64{}, durations: map[string]*histogram{}}
}

func (m *metrics) observe(route string, code int, d time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests[requestKey{route, code}]++
	h := m.durations[route]
	if h == nil {
		h = &histogram{counts: make([]uint64, len(durationBuckets)+1)}
		m.durations[route] = h
	}
	s := d.Seconds()
	i := sort.SearchFloat64s(durationBuckets, s) // first bucket with bound >= s
	h.counts[i]++
	h.sum += s
	h.count++
}

// statusRecorder keeps the status code a handler wrote.
type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) {
	if r.code == 0 {
		r.code = code
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if r.code == 0 {
		r.code = http.StatusOK
	}
	return r.ResponseWriter.Write(b)
}

// routeOf returns the matched pattern without its method.
func routeOf(r *http.Request) string {
	p := r.Pattern
	if p == "" {
		return "unmatched"
	}
	if i := strings.IndexByte(p, ' '); i >= 0 {
		p = p[i+1:]
	}
	return strings.TrimSuffix(p, "{$}")
}

// instrument wraps a ServeMux. The mux sets r.Pattern on the request it
// routes, which is the same request this middleware holds.
func (m *metrics) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		code := rec.code
		if code == 0 {
			code = http.StatusOK
		}
		m.observe(routeOf(r), code, time.Since(start))
	})
}

func escapeLabel(v string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(v)
}

func formatFloat(f float64) string {
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// write renders every series in a stable order.
func (m *metrics) write(w io.Writer) {
	m.mu.Lock()
	defer m.mu.Unlock()

	fmt.Fprintln(w, "# HELP smoke_build_info Build information of the smoke service.")
	fmt.Fprintln(w, "# TYPE smoke_build_info gauge")
	fmt.Fprintf(w, "smoke_build_info{version=\"%s\"} 1\n", escapeLabel(version))

	keys := make([]requestKey, 0, len(m.requests))
	for k := range m.requests {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].route != keys[j].route {
			return keys[i].route < keys[j].route
		}
		return keys[i].code < keys[j].code
	})
	fmt.Fprintln(w, "# HELP http_requests_total HTTP requests served, by route and status code.")
	fmt.Fprintln(w, "# TYPE http_requests_total counter")
	for _, k := range keys {
		fmt.Fprintf(w, "http_requests_total{route=\"%s\",code=\"%d\"} %d\n", escapeLabel(k.route), k.code, m.requests[k])
	}

	routes := make([]string, 0, len(m.durations))
	for r := range m.durations {
		routes = append(routes, r)
	}
	sort.Strings(routes)
	fmt.Fprintln(w, "# HELP http_request_duration_seconds Time to serve an HTTP request, by route.")
	fmt.Fprintln(w, "# TYPE http_request_duration_seconds histogram")
	for _, r := range routes {
		h := m.durations[r]
		route := escapeLabel(r)
		var cum uint64
		for i, le := range durationBuckets {
			cum += h.counts[i]
			fmt.Fprintf(w, "http_request_duration_seconds_bucket{route=\"%s\",le=\"%s\"} %d\n", route, formatFloat(le), cum)
		}
		cum += h.counts[len(durationBuckets)]
		fmt.Fprintf(w, "http_request_duration_seconds_bucket{route=\"%s\",le=\"+Inf\"} %d\n", route, cum)
		fmt.Fprintf(w, "http_request_duration_seconds_sum{route=\"%s\"} %s\n", route, formatFloat(h.sum))
		fmt.Fprintf(w, "http_request_duration_seconds_count{route=\"%s\"} %d\n", route, h.count)
	}
}

// handler serves GET /metrics on the metrics listener only.
func (m *metrics) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		m.write(w)
	})
	return mux
}
