from __future__ import annotations

import os

import pytest

TEST_DATABASE_URL = os.environ.get("AOLF_TEST_DATABASE_URL", "")

if not TEST_DATABASE_URL:
    pytest.skip(
        "Set AOLF_TEST_DATABASE_URL to a throwaway Postgres database to run these tests. "
        "With docker compose up, that is "
        "postgresql://postgres:postgres@postgres:5432/gurudev_test",
        allow_module_level=True,
    )

# Point the app at the test database before anything imports get_settings().
os.environ["DATABASE_URL"] = TEST_DATABASE_URL
os.environ["SESSION_SECRET"] = "test-session-secret"

from fastapi.testclient import TestClient  # noqa: E402

from app.auth.users import create_user  # noqa: E402
from app.db.migrations import apply_migrations  # noqa: E402
from app.db.session import db_connection  # noqa: E402
from app.main import create_app  # noqa: E402
from app.settings import get_settings  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def _migrated_database() -> None:
    get_settings.cache_clear()
    apply_migrations(TEST_DATABASE_URL)


@pytest.fixture(autouse=True)
def _clean_users() -> None:
    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("TRUNCATE app.app_users CASCADE")


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app())


@pytest.fixture
def staff_password() -> str:
    return "correct-horse-battery-staple"


@pytest.fixture
def staff_user(staff_password: str):
    with db_connection() as conn:
        return create_user(
            conn,
            email="staff@example.com",
            display_name="Staff Member",
            password=staff_password,
            roles=["staff"],
        )
