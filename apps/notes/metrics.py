"""Phase 6.3b (ADR-0023): request metrics in the Prometheus text exposition
format (version 0.0.4), written with the standard library - the same three
families as apps/smoke, so dashboards and rules treat both alike:

    notes_build_info{version}                    gauge, always 1
    http_requests_total{route,code}              counter
    http_request_duration_seconds{route}         histogram

route is a route the code declares, or "unmatched", never the path a
client sent, so cardinality is bounded by the code.
"""

import bisect
import threading

# Upper bounds in seconds; +Inf is implicit. Same buckets as apps/smoke.
DURATION_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5)


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _fmt(value: float) -> str:
    text = repr(float(value))
    return text[:-2] if text.endswith(".0") else text


class Metrics:
    def __init__(self, version: str):
        self._version = version
        self._lock = threading.Lock()
        self._requests: dict[tuple[str, int], int] = {}
        # route -> [per-bucket counts (len(BUCKETS)+1), sum, count]
        self._durations: dict[str, list] = {}

    def observe(self, route: str, code: int, seconds: float) -> None:
        with self._lock:
            key = (route, code)
            self._requests[key] = self._requests.get(key, 0) + 1
            h = self._durations.get(route)
            if h is None:
                h = [[0] * (len(DURATION_BUCKETS) + 1), 0.0, 0]
                self._durations[route] = h
            h[0][bisect.bisect_left(DURATION_BUCKETS, seconds)] += 1
            h[1] += seconds
            h[2] += 1

    def render(self) -> str:
        with self._lock:
            lines = [
                "# HELP notes_build_info Build information of the notes service.",
                "# TYPE notes_build_info gauge",
                f'notes_build_info{{version="{_escape(self._version)}"}} 1',
                "# HELP http_requests_total HTTP requests served, by route and status code.",
                "# TYPE http_requests_total counter",
            ]
            for (route, code) in sorted(self._requests):
                lines.append(
                    f'http_requests_total{{route="{_escape(route)}",code="{code}"}} {self._requests[(route, code)]}'
                )
            lines += [
                "# HELP http_request_duration_seconds Time to serve an HTTP request, by route.",
                "# TYPE http_request_duration_seconds histogram",
            ]
            for route in sorted(self._durations):
                counts, total, count = self._durations[route]
                r = _escape(route)
                cumulative = 0
                for bound, n in zip(DURATION_BUCKETS, counts):
                    cumulative += n
                    lines.append(f'http_request_duration_seconds_bucket{{route="{r}",le="{_fmt(bound)}"}} {cumulative}')
                cumulative += counts[-1]
                lines.append(f'http_request_duration_seconds_bucket{{route="{r}",le="+Inf"}} {cumulative}')
                lines.append(f'http_request_duration_seconds_sum{{route="{r}"}} {_fmt(total)}')
                lines.append(f'http_request_duration_seconds_count{{route="{r}"}} {count}')
            return "\n".join(lines) + "\n"
