"""Phase 6.3b (ADR-0023): apps/notes - the reference application's data
service. Standard library HTTP server, one dependency (pg8000).

    GET  /healthz   liveness: 200 while the process runs
    GET  /readyz    readiness: 200 once the schema exists and the database
                    answers; 503 while starting, when the database is
                    unreachable, and while draining
    GET  /notes     the 50 newest notes
    POST /notes     {"body": "..."} (1-1000 characters) -> 201 {"id": n}

Metrics are served on their own port (METRICS_PORT), never on the
application port, as for apps/smoke. Logs are JSON lines on stdout. The
database password is read from a mounted file (ESO-built Secret), never
from the environment.
"""

import json
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from metrics import Metrics

VERSION = os.environ.get("VERSION", "dev")
MAX_BODY_BYTES = 4096


def log(level: str, msg: str, **fields) -> None:
    record = {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "level": level, "msg": msg}
    record.update(fields)
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()


class Config:
    def __init__(self, env: dict):
        self.port = self._port(env, "PORT", 8080)
        self.metrics_port = self._port(env, "METRICS_PORT", 9090)
        if self.port == self.metrics_port:
            raise ValueError("PORT and METRICS_PORT must differ")
        self.db_host = env.get("DB_HOST", "")
        if not self.db_host:
            raise ValueError("DB_HOST is required")
        self.db_port = self._port(env, "DB_PORT", 5432)
        self.db_name = env.get("DB_NAME", "notes")
        self.db_user = env.get("DB_USER", "notes")
        self.db_password_file = env.get("DB_PASSWORD_FILE", "/var/run/secrets/notes-db/password")
        # The standard chart passes SHUTDOWN_TIMEOUT ("5s") to every
        # workload; notes drains for that long after failing readiness.
        raw = env.get("SHUTDOWN_TIMEOUT", "5s")
        if not (raw.endswith("s") and raw[:-1].isdigit() and 0 < int(raw[:-1]) <= 60):
            raise ValueError(f"SHUTDOWN_TIMEOUT must be whole seconds between 1s and 60s, got {raw!r}")
        self.drain_seconds = float(raw[:-1])

    @staticmethod
    def _port(env: dict, name: str, default: int) -> int:
        raw = env.get(name, str(default))
        if not raw.isdigit() or not 1 <= int(raw) <= 65535:
            raise ValueError(f"{name} must be a port number (1-65535), got {raw!r}")
        return int(raw)


class Service:
    """Routes and state, independent of the HTTP server (unit-testable)."""

    def __init__(self, store, metrics: Metrics):
        self.store = store
        self.metrics = metrics
        self.schema_ready = threading.Event()
        self.draining = threading.Event()

    def ensure_schema_until_ready(self, stop: threading.Event, interval: float = 2.0) -> None:
        while not stop.is_set() and not self.schema_ready.is_set():
            try:
                self.store.ensure_schema()
                self.schema_ready.set()
                log("INFO", "schema ready")
            except Exception as exc:  # database not reachable yet
                log("WARN", "database not ready", error=type(exc).__name__)
                stop.wait(interval)

    def handle(self, method: str, path: str, body: bytes) -> tuple[str, int, dict]:
        """Returns (route, status, json payload)."""
        path = path.split("?", 1)[0]
        if path == "/healthz":
            return ("/healthz", 200, {"status": "ok"}) if method == "GET" else ("/healthz", 405, {"error": "method not allowed"})
        if path == "/readyz":
            if method != "GET":
                return "/readyz", 405, {"error": "method not allowed"}
            if self.draining.is_set() or not self.schema_ready.is_set():
                return "/readyz", 503, {"status": "not ready"}
            try:
                self.store.ping()
            except Exception:
                return "/readyz", 503, {"status": "database unreachable"}
            return "/readyz", 200, {"status": "ready"}
        if path == "/notes":
            if not self.schema_ready.is_set():
                return "/notes", 503, {"error": "not ready"}
            if method == "GET":
                try:
                    return "/notes", 200, {"notes": self.store.list_notes()}
                except Exception:
                    return "/notes", 503, {"error": "database unavailable"}
            if method == "POST":
                try:
                    payload = json.loads(body or b"{}")
                except ValueError:
                    return "/notes", 400, {"error": "body must be JSON"}
                text = payload.get("body") if isinstance(payload, dict) else None
                if not isinstance(text, str) or not 1 <= len(text) <= 1000:
                    return "/notes", 400, {"error": "body must be a string of 1-1000 characters"}
                try:
                    return "/notes", 201, {"id": self.store.add_note(text)}
                except Exception:
                    return "/notes", 503, {"error": "database unavailable"}
            return "/notes", 405, {"error": "method not allowed"}
        return "unmatched", 404, {"error": "not found"}


def make_app_handler(service: Service):
    class Handler(BaseHTTPRequestHandler):
        server_version = "notes"
        sys_version = ""

        def _serve(self, method: str) -> None:
            start = time.monotonic()
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY_BYTES:
                route, status, payload = "/notes", 413, {"error": "body too large"}
            else:
                body = self.rfile.read(length) if length else b""
                route, status, payload = service.handle(method, self.path, body)
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            service.metrics.observe(route, status, time.monotonic() - start)

        def do_GET(self):  # noqa: N802 (http.server naming)
            self._serve("GET")

        def do_POST(self):  # noqa: N802
            self._serve("POST")

        def do_PUT(self):  # noqa: N802
            self._serve("PUT")

        def do_DELETE(self):  # noqa: N802
            self._serve("DELETE")

        def log_message(self, fmt, *args):  # access logs off; errors are logged by the service
            return

    return Handler


def make_metrics_handler(metrics: Metrics):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            if self.path.split("?", 1)[0] != "/metrics":
                self.send_error(404)
                return
            data = metrics.render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt, *args):
            return

    return Handler


def main() -> int:
    try:
        cfg = Config(dict(os.environ))
    except ValueError as exc:
        log("ERROR", "invalid configuration", error=str(exc))
        return 2
    from store import PostgresStore

    store = PostgresStore(cfg.db_host, cfg.db_port, cfg.db_name, cfg.db_user, cfg.db_password_file)
    metrics = Metrics(VERSION)
    service = Service(store, metrics)
    stop = threading.Event()

    app = ThreadingHTTPServer(("", cfg.port), make_app_handler(service))
    metrics_server = ThreadingHTTPServer(("", cfg.metrics_port), make_metrics_handler(metrics))
    app.daemon_threads = metrics_server.daemon_threads = True
    for srv in (app, metrics_server):
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    threading.Thread(target=service.ensure_schema_until_ready, args=(stop,), daemon=True).start()
    log("INFO", "listening", addr=f":{cfg.port}", metrics=f":{cfg.metrics_port}", version=VERSION)

    def on_term(signum, _frame):
        stop.set()

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    stop.wait()
    # Fail readiness first, so endpoints drop this pod, then stop serving.
    service.draining.set()
    log("INFO", "shutting down", drain_seconds=cfg.drain_seconds)
    time.sleep(cfg.drain_seconds)
    app.shutdown()
    metrics_server.shutdown()
    log("INFO", "stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
