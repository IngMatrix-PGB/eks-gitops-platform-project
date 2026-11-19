"""Unit tests for apps/notes (standard library unittest; no database)."""

import json
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

from app import Config, Service, make_app_handler, make_metrics_handler
from metrics import Metrics


class FakeStore:
    def __init__(self, up=True):
        self.up = up
        self.notes = []

    def _check(self):
        if not self.up:
            raise ConnectionError("down")

    def ping(self):
        self._check()

    def ensure_schema(self):
        self._check()

    def list_notes(self, limit=50):
        self._check()
        return list(reversed(self.notes))[:limit]

    def add_note(self, body):
        self._check()
        self.notes.append({"id": len(self.notes) + 1, "body": body, "created_at": "t"})
        return len(self.notes)


def ready_service(store=None):
    svc = Service(store or FakeStore(), Metrics("test"))
    svc.schema_ready.set()
    return svc


class ConfigTest(unittest.TestCase):
    def test_defaults(self):
        c = Config({"DB_HOST": "db"})
        self.assertEqual((c.port, c.metrics_port, c.db_port, c.db_name, c.db_user), (8080, 9090, 5432, "notes", "notes"))
        self.assertEqual(c.drain_seconds, 5.0)
        self.assertEqual(Config({"DB_HOST": "db", "SHUTDOWN_TIMEOUT": "7s"}).drain_seconds, 7.0)

    def test_rejects_bad_ports_and_missing_host(self):
        for env in ({}, {"DB_HOST": "db", "PORT": "0"}, {"DB_HOST": "db", "PORT": "x"},
                    {"DB_HOST": "db", "METRICS_PORT": "70000"}, {"DB_HOST": "db", "PORT": "9090"},
                    {"DB_HOST": "db", "SHUTDOWN_TIMEOUT": "5"}, {"DB_HOST": "db", "SHUTDOWN_TIMEOUT": "0s"},
                    {"DB_HOST": "db", "SHUTDOWN_TIMEOUT": "2m"}):
            with self.assertRaises(ValueError, msg=str(env)):
                Config(env)


class RoutesTest(unittest.TestCase):
    def test_health_always_ok(self):
        self.assertEqual(Service(FakeStore(), Metrics("t")).handle("GET", "/healthz", b"")[1], 200)

    def test_readiness_states(self):
        store = FakeStore()
        svc = Service(store, Metrics("t"))
        self.assertEqual(svc.handle("GET", "/readyz", b"")[1], 503)  # schema not ready
        svc.schema_ready.set()
        self.assertEqual(svc.handle("GET", "/readyz", b"")[1], 200)
        store.up = False
        self.assertEqual(svc.handle("GET", "/readyz", b"")[1], 503)  # database down
        store.up = True
        svc.draining.set()
        self.assertEqual(svc.handle("GET", "/readyz", b"")[1], 503)  # draining

    def test_create_then_list(self):
        svc = ready_service()
        route, code, payload = svc.handle("POST", "/notes", json.dumps({"body": "hello"}).encode())
        self.assertEqual((route, code, payload), ("/notes", 201, {"id": 1}))
        svc.handle("POST", "/notes", b'{"body": "second"}')
        _, code, payload = svc.handle("GET", "/notes?x=1", b"")
        self.assertEqual(code, 200)
        self.assertEqual([n["body"] for n in payload["notes"]], ["second", "hello"])

    def test_validation(self):
        svc = ready_service()
        for body in (b"not json", b"[]", b'{"body": ""}', b'{"body": 5}', json.dumps({"body": "x" * 1001}).encode()):
            self.assertEqual(svc.handle("POST", "/notes", body)[1], 400, body)

    def test_database_down_is_503_not_500(self):
        svc = ready_service(FakeStore(up=False))
        self.assertEqual(svc.handle("GET", "/notes", b"")[1], 503)
        self.assertEqual(svc.handle("POST", "/notes", b'{"body": "x"}')[1], 503)

    def test_unknown_paths_and_methods(self):
        svc = ready_service()
        self.assertEqual(svc.handle("GET", "/nope", b"")[:2], ("unmatched", 404))
        self.assertEqual(svc.handle("DELETE", "/notes", b"")[:2], ("/notes", 405))

    def test_schema_retry_until_database_answers(self):
        store = FakeStore(up=False)
        svc = Service(store, Metrics("t"))
        stop = threading.Event()
        t = threading.Thread(target=svc.ensure_schema_until_ready, args=(stop, 0.01))
        t.start()
        self.assertFalse(svc.schema_ready.wait(0.05))
        store.up = True
        self.assertTrue(svc.schema_ready.wait(1))
        stop.set()
        t.join(1)


class MetricsTest(unittest.TestCase):
    def test_counts_buckets_and_escaping(self):
        m = Metrics('v"1')
        m.observe("/notes", 201, 0.003)
        m.observe("/notes", 201, 7.1)
        m.observe("unmatched", 404, 0.02)
        text = m.render()
        self.assertIn('notes_build_info{version="v\\"1"} 1', text)
        self.assertIn('http_requests_total{route="/notes",code="201"} 2', text)
        self.assertIn('http_request_duration_seconds_bucket{route="/notes",le="0.005"} 1', text)
        self.assertIn('http_request_duration_seconds_bucket{route="/notes",le="5"} 1', text)
        self.assertIn('http_request_duration_seconds_bucket{route="/notes",le="+Inf"} 2', text)
        self.assertIn('http_request_duration_seconds_count{route="/notes"} 2', text)
        self.assertNotIn("/nope", text)


class ServersTest(unittest.TestCase):
    """The real handlers over HTTP: metrics only on the metrics listener."""

    def setUp(self):
        self.svc = ready_service()
        self.app = ThreadingHTTPServer(("127.0.0.1", 0), make_app_handler(self.svc))
        self.met = ThreadingHTTPServer(("127.0.0.1", 0), make_metrics_handler(self.svc.metrics))
        for s in (self.app, self.met):
            threading.Thread(target=s.serve_forever, daemon=True).start()

    def tearDown(self):
        for s in (self.app, self.met):
            s.shutdown()
            s.server_close()

    def _code(self, port, path, data=None):
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method="POST" if data else "GET")
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def test_end_to_end(self):
        code, _ = self._code(self.app.server_address[1], "/notes", b'{"body": "hi"}')
        self.assertEqual(code, 201)
        self.assertEqual(self._code(self.app.server_address[1], "/metrics")[0], 404)
        code, body = self._code(self.met.server_address[1], "/metrics")
        self.assertEqual(code, 200)
        self.assertIn(b'http_requests_total{route="/notes",code="201"} 1', body)
        self.assertIn(b'route="unmatched",code="404"', body)  # the /metrics probe on the app port


if __name__ == "__main__":
    unittest.main()
