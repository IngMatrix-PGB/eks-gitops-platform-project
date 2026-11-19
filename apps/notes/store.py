"""Phase 6.3b (ADR-0023): the notes table in PostgreSQL, through pg8000's
native interface (pure Python, parameterized queries only).

A connection per call keeps the service stateless and the code small; the
reference workload's traffic does not need a pool.
"""

import pg8000.native

SCHEMA = """
CREATE TABLE IF NOT EXISTS notes (
    id         BIGSERIAL PRIMARY KEY,
    body       TEXT NOT NULL CHECK (char_length(body) BETWEEN 1 AND 1000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
"""


class PostgresStore:
    def __init__(self, host: str, port: int, database: str, user: str, password_file: str, timeout: float = 5.0):
        self._host = host
        self._port = port
        self._database = database
        self._user = user
        self._password_file = password_file
        self._timeout = timeout

    def _connect(self) -> pg8000.native.Connection:
        # Read on every connection: a rotated Secret is picked up without a
        # restart once the kubelet refreshes the mounted file.
        with open(self._password_file, encoding="utf-8") as f:
            password = f.read().strip()
        return pg8000.native.Connection(
            user=self._user, password=password, host=self._host, port=self._port,
            database=self._database, timeout=self._timeout,
        )

    def ping(self) -> None:
        conn = self._connect()
        try:
            conn.run("SELECT 1")
        finally:
            conn.close()

    def ensure_schema(self) -> None:
        conn = self._connect()
        try:
            conn.run(SCHEMA)
        finally:
            conn.close()

    def list_notes(self, limit: int = 50) -> list[dict]:
        conn = self._connect()
        try:
            rows = conn.run(
                "SELECT id, body, created_at FROM notes ORDER BY id DESC LIMIT :limit", limit=limit
            )
        finally:
            conn.close()
        return [{"id": r[0], "body": r[1], "created_at": r[2].isoformat()} for r in rows]

    def add_note(self, body: str) -> int:
        conn = self._connect()
        try:
            rows = conn.run("INSERT INTO notes (body) VALUES (:body) RETURNING id", body=body)
        finally:
            conn.close()
        return rows[0][0]
