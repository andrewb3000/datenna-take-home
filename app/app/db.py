import os
import time

import psycopg


def _dsn() -> str:
    return (
        f"host={os.environ['DB_HOST']} "
        f"port={os.environ['DB_PORT']} "
        f"dbname={os.environ['DB_NAME']} "
        f"user={os.environ['DB_USER']} "
        f"password={os.environ['DB_PASSWORD']}"
    )


def wait_for_db(retries: int = 10, delay_seconds: float = 2.0) -> None:
    # Schema (the `items` table) is provisioned once, out of band, by Postgres's
    # own initdb script (k8s/10-postgres.yaml) running as the superuser — app_user
    # has no CREATE privilege on the schema (Postgres 15+ default), by design: the
    # app does DML only, never DDL. This just waits for connectivity.
    last_error: Exception | None = None
    for _ in range(retries):
        try:
            with psycopg.connect(_dsn(), connect_timeout=3) as conn:
                conn.execute("SELECT 1")
            return
        except psycopg.OperationalError as exc:
            last_error = exc
            time.sleep(delay_seconds)
    raise RuntimeError(f"could not reach Postgres after {retries} attempts") from last_error


def insert_item(value: str) -> int:
    with psycopg.connect(_dsn()) as conn:
        row = conn.execute(
            "INSERT INTO items (value) VALUES (%s) RETURNING id", (value,)
        ).fetchone()
        conn.commit()
        return row[0]


def delete_item(item_id: int) -> None:
    with psycopg.connect(_dsn()) as conn:
        conn.execute("DELETE FROM items WHERE id = %s", (item_id,))
        conn.commit()


def get_item(item_id: int) -> dict | None:
    with psycopg.connect(_dsn()) as conn:
        row = conn.execute(
            "SELECT id, value, created_at FROM items WHERE id = %s", (item_id,)
        ).fetchone()
        if row is None:
            return None
        return {"id": row[0], "value": row[1], "created_at": row[2].isoformat()}


def ping() -> bool:
    try:
        with psycopg.connect(_dsn(), connect_timeout=3) as conn:
            conn.execute("SELECT 1")
        return True
    except Exception:
        return False
