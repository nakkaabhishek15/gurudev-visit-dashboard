from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

from psycopg import Connection

from app.auth.models import AppUser
from app.auth.passwords import (
    WeakPasswordError,
    dummy_verify,
    hash_password,
    needs_rehash,
    verify_password,
)
from app.auth.roles import DEFAULT_ROLE, normalize_roles
from app.db.session import db_connection
from app.settings import get_settings


class AuthError(Exception):
    """Base class for login failures."""


class InvalidCredentials(AuthError):
    pass


class AccountInactive(AuthError):
    pass


class AccountLocked(AuthError):
    def __init__(self, locked_until: datetime) -> None:
        super().__init__("Account is temporarily locked.")
        self.locked_until = locked_until


def load_app_user(conn: Connection, app_user_id: UUID) -> AppUser | None:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT app_user_id, email, display_name, is_active
            FROM app.app_users
            WHERE app_user_id = %s
            """,
            (app_user_id,),
        )
        row = cur.fetchone()
    if row is None or not row["is_active"]:
        return None
    return AppUser(
        app_user_id=row["app_user_id"],
        email=str(row["email"]),
        display_name=row["display_name"],
        roles=_load_roles(conn, row["app_user_id"]),
    )


def authenticate(email: str, password: str) -> AppUser:
    """Return the user when the password matches, otherwise raise an AuthError.

    This opens its own short transactions rather than borrowing the caller's.
    A failed attempt must be committed even though the call then raises, and a
    single caller-owned transaction would roll that write back on the way out --
    silently disabling the lockout counter.
    """
    settings = get_settings()
    normalized_email = email.strip().lower()

    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT app_user_id, email, display_name, password_hash, is_active,
                       failed_logins, locked_until
                FROM app.app_users
                WHERE email = %s
                """,
                (normalized_email,),
            )
            row = cur.fetchone()

    if row is None:
        dummy_verify(password)
        raise InvalidCredentials("Invalid email or password.")

    now = datetime.now(timezone.utc)
    locked_until = row["locked_until"]
    if locked_until is not None and locked_until > now:
        raise AccountLocked(locked_until)

    if not verify_password(row["password_hash"], password):
        with db_connection() as conn:
            _record_failed_login(conn, row["app_user_id"], row["failed_logins"], now, settings)
        raise InvalidCredentials("Invalid email or password.")

    # Password is correct from here on. An inactive account still must not sign in.
    if not row["is_active"]:
        raise AccountInactive("This account is disabled.")

    with db_connection() as conn:
        _record_successful_login(conn, row["app_user_id"], now)
        if needs_rehash(row["password_hash"]):
            try:
                set_password(conn, normalized_email, password)
            except WeakPasswordError:
                # The stored password predates a stricter policy. Let the user in
                # and leave the old hash alone rather than failing a valid login.
                pass
        roles = _load_roles(conn, row["app_user_id"])

    return AppUser(
        app_user_id=row["app_user_id"],
        email=str(row["email"]),
        display_name=row["display_name"],
        roles=roles,
    )


def create_user(
    conn: Connection,
    *,
    email: str,
    display_name: str,
    password: str,
    roles: list[str] | None = None,
) -> AppUser:
    normalized_email = email.strip().lower()
    normalized_roles = normalize_roles(roles)
    password_hash = hash_password(password)

    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO app.app_users (email, display_name, password_hash)
            VALUES (%s, %s, %s)
            ON CONFLICT (email) DO UPDATE
                SET display_name  = EXCLUDED.display_name,
                    password_hash = EXCLUDED.password_hash,
                    is_active     = true,
                    failed_logins = 0,
                    locked_until  = NULL,
                    updated_at    = now()
            RETURNING app_user_id, email, display_name
            """,
            (normalized_email, display_name.strip(), password_hash),
        )
        row = cur.fetchone()

        cur.execute("DELETE FROM app.app_user_roles WHERE app_user_id = %s", (row["app_user_id"],))
        for role in normalized_roles:
            cur.execute(
                "INSERT INTO app.app_user_roles (app_user_id, role_key) VALUES (%s, %s)",
                (row["app_user_id"], role),
            )

    return AppUser(
        app_user_id=row["app_user_id"],
        email=str(row["email"]),
        display_name=row["display_name"],
        roles=normalized_roles,
    )


def set_password(conn: Connection, email: str, password: str) -> None:
    password_hash = hash_password(password)
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE app.app_users
            SET password_hash = %s,
                failed_logins = 0,
                locked_until  = NULL,
                updated_at    = now()
            WHERE email = %s
            """,
            (password_hash, email.strip().lower()),
        )
        if cur.rowcount == 0:
            raise LookupError(f"No user with email {email}.")


def set_active(conn: Connection, email: str, is_active: bool) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE app.app_users SET is_active = %s, updated_at = now() WHERE email = %s",
            (is_active, email.strip().lower()),
        )
        if cur.rowcount == 0:
            raise LookupError(f"No user with email {email}.")


def list_users(conn: Connection) -> list[dict[str, object]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT u.app_user_id,
                   u.email,
                   u.display_name,
                   u.is_active,
                   u.last_login_at,
                   COALESCE(array_agg(r.role_key ORDER BY r.role_key)
                            FILTER (WHERE r.role_key IS NOT NULL), '{}') AS roles
            FROM app.app_users u
            LEFT JOIN app.app_user_roles r ON r.app_user_id = u.app_user_id
            GROUP BY u.app_user_id
            ORDER BY u.email
            """
        )
        return [dict(row) for row in cur.fetchall()]


def _load_roles(conn: Connection, app_user_id: UUID) -> list[str]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT role_key FROM app.app_user_roles WHERE app_user_id = %s ORDER BY role_key",
            (app_user_id,),
        )
        roles = [row["role_key"] for row in cur.fetchall()]
    return roles or [DEFAULT_ROLE]


def _record_failed_login(
    conn: Connection,
    app_user_id: UUID,
    failed_logins: int,
    now: datetime,
    settings,
) -> None:
    attempts = failed_logins + 1
    locked_until = None
    if settings.max_failed_logins > 0 and attempts >= settings.max_failed_logins:
        locked_until = now + timedelta(minutes=settings.lockout_minutes)
        attempts = 0
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE app.app_users
            SET failed_logins = %s, locked_until = %s, updated_at = now()
            WHERE app_user_id = %s
            """,
            (attempts, locked_until, app_user_id),
        )


def _record_successful_login(conn: Connection, app_user_id: UUID, now: datetime) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE app.app_users
            SET failed_logins = 0, locked_until = NULL, last_login_at = %s, updated_at = now()
            WHERE app_user_id = %s
            """,
            (now, app_user_id),
        )
