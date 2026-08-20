from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.auth.passwords import WeakPasswordError, hash_password, verify_password
from app.auth.users import create_user, set_active
from app.db.session import db_connection
from app.settings import get_settings


def test_password_hash_round_trip() -> None:
    password_hash = hash_password("correct-horse-battery-staple")
    assert verify_password(password_hash, "correct-horse-battery-staple")
    assert not verify_password(password_hash, "wrong-horse-battery-staple")


def test_short_password_is_rejected() -> None:
    with pytest.raises(WeakPasswordError):
        hash_password("short")


def test_login_sets_session_and_me_returns_user(
    client: TestClient, staff_user, staff_password: str
) -> None:
    response = client.post(
        "/api/auth/login",
        json={"email": "staff@example.com", "password": staff_password},
    )
    assert response.status_code == 200
    assert response.json()["email"] == "staff@example.com"
    assert response.json()["role"] == "staff"

    me = client.get("/api/auth/me")
    assert me.status_code == 200
    assert me.json()["display_name"] == "Staff Member"


def test_me_requires_authentication(client: TestClient) -> None:
    assert client.get("/api/auth/me").status_code == 401


def test_wrong_password_is_rejected(client: TestClient, staff_user) -> None:
    response = client.post(
        "/api/auth/login",
        json={"email": "staff@example.com", "password": "not-the-password"},
    )
    assert response.status_code == 401
    assert client.get("/api/auth/me").status_code == 401


def test_unknown_email_and_wrong_password_report_the_same_error(
    client: TestClient, staff_user
) -> None:
    unknown = client.post(
        "/api/auth/login",
        json={"email": "nobody@example.com", "password": "not-the-password"},
    )
    wrong = client.post(
        "/api/auth/login",
        json={"email": "staff@example.com", "password": "not-the-password"},
    )
    assert unknown.status_code == wrong.status_code == 401
    assert unknown.json()["detail"] == wrong.json()["detail"]


def test_email_is_case_insensitive(client: TestClient, staff_user, staff_password: str) -> None:
    response = client.post(
        "/api/auth/login",
        json={"email": "STAFF@Example.com", "password": staff_password},
    )
    assert response.status_code == 200


def test_disabled_account_cannot_sign_in(
    client: TestClient, staff_user, staff_password: str
) -> None:
    with db_connection() as conn:
        set_active(conn, "staff@example.com", False)

    response = client.post(
        "/api/auth/login",
        json={"email": "staff@example.com", "password": staff_password},
    )
    assert response.status_code == 403


def test_logout_clears_the_session(
    client: TestClient, staff_user, staff_password: str
) -> None:
    client.post(
        "/api/auth/login",
        json={"email": "staff@example.com", "password": staff_password},
    )
    assert client.post("/api/auth/logout").status_code == 200
    assert client.get("/api/auth/me").status_code == 401


def test_repeated_failures_lock_the_account(
    client: TestClient, staff_user, staff_password: str
) -> None:
    limit = get_settings().max_failed_logins
    for _ in range(limit):
        client.post(
            "/api/auth/login",
            json={"email": "staff@example.com", "password": "not-the-password"},
        )

    # The correct password is now refused too, which is the point of the lockout.
    response = client.post(
        "/api/auth/login",
        json={"email": "staff@example.com", "password": staff_password},
    )
    assert response.status_code == 423


def test_admin_endpoint_rejects_staff_role(
    client: TestClient, staff_user, staff_password: str
) -> None:
    client.post(
        "/api/auth/login",
        json={"email": "staff@example.com", "password": staff_password},
    )
    assert client.get("/api/admin/users").status_code == 403


def test_admin_endpoint_allows_admin_role(client: TestClient) -> None:
    password = "admin-correct-horse-staple"
    with db_connection() as conn:
        create_user(
            conn,
            email="admin@example.com",
            display_name="Admin",
            password=password,
            roles=["admin"],
        )

    client.post("/api/auth/login", json={"email": "admin@example.com", "password": password})
    response = client.get("/api/admin/users")
    assert response.status_code == 200
    assert any(user["email"] == "admin@example.com" for user in response.json()["users"])


def test_unknown_role_is_rejected() -> None:
    with db_connection() as conn:
        with pytest.raises(ValueError):
            create_user(
                conn,
                email="nope@example.com",
                display_name="Nope",
                password="correct-horse-battery-staple",
                roles=["superuser"],
            )
