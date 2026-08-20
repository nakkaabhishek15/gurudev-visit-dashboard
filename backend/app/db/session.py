from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

import psycopg
from psycopg.rows import dict_row

from app.settings import get_settings


def connect(database_url: str | None = None) -> psycopg.Connection:
    url = database_url or get_settings().database_url
    if not url:
        raise RuntimeError("DATABASE_URL is required")
    return psycopg.connect(url, row_factory=dict_row)


@contextmanager
def db_connection(database_url: str | None = None) -> Iterator[psycopg.Connection]:
    conn = connect(database_url)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@contextmanager
def warehouse_connection() -> Iterator[psycopg.Connection]:
    """Read-only connection to the AOLF warehouse.

    Opened read-only at the session level so a bug in report SQL cannot write to
    the warehouse even if the database role were over-privileged. The role
    should still be read-only; this is the second lock, not the first.
    """
    url = get_settings().warehouse_url()
    if not url:
        raise RuntimeError("WAREHOUSE_DATABASE_URL (or DATABASE_URL) is required")
    conn = psycopg.connect(url, row_factory=dict_row)
    try:
        conn.read_only = True
        yield conn
    finally:
        conn.close()
