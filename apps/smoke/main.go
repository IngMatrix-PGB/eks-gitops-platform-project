// Command smoke is the platform's first-party reference workload (Phase
// 5.1a): a minimal HTTP service whose only job is to honor the
// standard-workload chart's contract, so the image supply chain (build,
// scan, SBOM, and later signing and promotion) has something of our own
// to carry. Phase 6.3 grows it into the multi-language reference app.
//
// Contract with charts/standard-workload:
//   - listens on PORT (default 9898, the chart's service.port);
//   - GET /healthz: 200 while the process runs (liveness);
//   - GET /readyz: 200 until SIGTERM, then 503 (readiness), so the
//     endpoint leaves the Service while the preStop sleep runs;
//   - GET /: a short JSON document with UI_MESSAGE and the version;
//   - on SIGTERM: stop accepting new connections and drain in-flight
//     requests for at most SHUTDOWN_TIMEOUT (default 5s).
//
// The podinfo-era variable names (PODINFO_UI_MESSAGE,
// PODINFO_SERVER_SHUTDOWN_TIMEOUT) are read as fallbacks, so the chart
// can switch images before it renames its environment variables.
// Standard library only; runs as a non-root user on a read-only root
// filesystem with no writable path needed.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

type config struct {
	port            int
	uiMessage       string
	shutdownTimeout time.Duration
}

// lookup returns the first non-empty value among the given variables.
func lookup(getenv func(string) string, names ...string) string {
	for _, n := range names {
		if v := getenv(n); v != "" {
			return v
		}
	}
	return ""
}

func loadConfig(getenv func(string) string) (config, error) {
	c := config{port: 9898, uiMessage: "smoke", shutdownTimeout: 5 * time.Second}
	if v := lookup(getenv, "PORT"); v != "" {
		p, err := strconv.Atoi(v)
		if err != nil || p < 1 || p > 65535 {
			return c, errors.New("PORT must be an integer between 1 and 65535")
		}
		c.port = p
	}
	if v := lookup(getenv, "UI_MESSAGE", "PODINFO_UI_MESSAGE"); v != "" {
		c.uiMessage = v
	}
	if v := lookup(getenv, "SHUTDOWN_TIMEOUT", "PODINFO_SERVER_SHUTDOWN_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 || d > time.Minute {
			return c, errors.New("SHUTDOWN_TIMEOUT must be a positive duration of at most 1m (e.g. 5s)")
		}
		c.shutdownTimeout = d
	}
	return c, nil
}

func newHandler(c config, ready *atomic.Bool) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !ready.Load() {
			http.Error(w, "shutting down", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ready\n"))
	})
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"message": c.uiMessage,
			"version": version,
		})
	})
	return mux
}

// run serves until ctx is cancelled, then marks the service not ready
// and drains in-flight requests for at most c.shutdownTimeout.
func run(ctx context.Context, ln net.Listener, c config, log *slog.Logger) error {
	var ready atomic.Bool
	ready.Store(true)
	srv := &http.Server{
		Handler:           newHandler(c, &ready),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	log.Info("listening", "addr", ln.Addr().String(), "version", version)

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	ready.Store(false)
	log.Info("shutting down", "timeout", c.shutdownTimeout.String())
	sctx, cancel := context.WithTimeout(context.Background(), c.shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(sctx); err != nil {
		return err
	}
	if err := <-errc; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	c, err := loadConfig(os.Getenv)
	if err != nil {
		log.Error("invalid configuration", "error", err.Error())
		os.Exit(2)
	}
	ln, err := net.Listen("tcp", ":"+strconv.Itoa(c.port))
	if err != nil {
		log.Error("listen failed", "error", err.Error())
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	if err := run(ctx, ln, c, log); err != nil {
		log.Error("server error", "error", err.Error())
		os.Exit(1)
	}
	log.Info("stopped")
}
