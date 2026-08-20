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
