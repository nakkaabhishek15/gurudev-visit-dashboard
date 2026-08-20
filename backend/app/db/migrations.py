"""Forward-only SQL migrations.

Each entry is (key, statements). Keys are recorded in app.schema_migrations so a
migration runs exactly once. Never edit an applied migration -- add a new one.

Deploys run this through `terraform/scripts/run_backend_migrations.sh`, which
starts a one-off ECS task with:

    python -c "from app.db.migrations import apply_migrations; apply_migrations()"
"""

from __future__ import annotations

from psycopg import Connection

from app.db.session import db_connection

MIGRATIONS: list[tuple[str, str]] = [
    (
        "0001_app_schema",
        """
        CREATE SCHEMA IF NOT EXISTS app;
        CREATE EXTENSION IF NOT EXISTS citext;
        CREATE EXTENSION IF NOT EXISTS pgcrypto;
        """,
    ),
    (
        "0002_app_users",
        """
        CREATE TABLE IF NOT EXISTS app.app_users (
            app_user_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            email           citext NOT NULL UNIQUE,
            display_name    text NOT NULL,
            password_hash   text NOT NULL,
            is_active       boolean NOT NULL DEFAULT true,
            failed_logins   integer NOT NULL DEFAULT 0,
            locked_until    timestamptz,
            last_login_at   timestamptz,
            created_at      timestamptz NOT NULL DEFAULT now(),
            updated_at      timestamptz NOT NULL DEFAULT now()
        );

        CREATE TABLE IF NOT EXISTS app.app_user_roles (
            app_user_id uuid NOT NULL REFERENCES app.app_users (app_user_id) ON DELETE CASCADE,
            role_key    text NOT NULL,
            PRIMARY KEY (app_user_id, role_key)
        );
        """,
    ),
]


def apply_migrations(database_url: str | None = None) -> list[str]:
    """Apply every unapplied migration. Returns the keys that ran."""
    applied: list[str] = []
    with db_connection(database_url) as conn:
        _ensure_migrations_table(conn)
        already = _applied_keys(conn)
        for key, statements in MIGRATIONS:
            if key in already:
                continue
            with conn.cursor() as cur:
                cur.execute(statements)
                cur.execute(
                    "INSERT INTO app.schema_migrations (migration_key) VALUES (%s)",
                    (key,),
                )
            applied.append(key)
    for key in applied:
        print(f"applied migration {key}")
    if not applied:
        print("no migrations to apply")
    return applied


def _ensure_migrations_table(conn: Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("CREATE SCHEMA IF NOT EXISTS app")
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS app.schema_migrations (
                migration_key text PRIMARY KEY,
                applied_at    timestamptz NOT NULL DEFAULT now()
            )
            """
        )


def _applied_keys(conn: Connection) -> set[str]:
    with conn.cursor() as cur:
        cur.execute("SELECT migration_key FROM app.schema_migrations")
        return {row["migration_key"] for row in cur.fetchall()}


if __name__ == "__main__":
    apply_migrations()
