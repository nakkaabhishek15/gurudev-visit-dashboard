"""Guards on the Retreat Guru reporting endpoints.

These cover the checks that run before any warehouse query, so they need no
warehouse: authentication, the course allowlist, and dimension validation. The
SQL itself is exercised against the real warehouse over the SSM tunnel, which no
CI runner can reach.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.auth.users import create_user
from app.db.session import db_connection

REPORT = "/api/reports/retreat-guru-course-demographics"


@pytest.fixture
def signed_in(client: TestClient) -> TestClient:
    password = "correct-horse-battery-staple"
    with db_connection() as conn:
        create_user(
            conn,
            email="reader@example.com",
            display_name="Report Reader",
            password=password,
            roles=["staff"],
        )
    response = client.post(
        "/api/auth/login",
        json={"email": "reader@example.com", "password": password},
    )
    assert response.status_code == 200
    return client


def test_reports_require_authentication(client: TestClient) -> None:
    assert client.get(REPORT).status_code == 401
    assert client.get(f"{REPORT}/courses").status_code == 401


def test_course_outside_the_allowlist_is_refused(signed_in: TestClient) -> None:
    """A signed-in user must not reach other Retreat Guru courses by editing the URL."""
    response = signed_in.get(REPORT, params={"course_id": "9999"})
    assert response.status_code == 400
    assert "9999" not in response.json()["detail"]


def test_unknown_dimension_is_refused(signed_in: TestClient) -> None:
    response = signed_in.get(REPORT, params={"dimension": "Gender"})
    assert response.status_code == 400
    detail = response.json()["detail"]
    assert "Province" in detail and "City" in detail and "Country" in detail


def test_disallowed_course_is_refused_before_the_warehouse_is_touched(
    signed_in: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The allowlist check must not depend on a reachable warehouse."""

    def explode(*args: object, **kwargs: object):
        raise AssertionError("warehouse_connection must not be opened for a rejected request")

    monkeypatch.setattr("app.api.reports.warehouse_connection", explode)
    assert signed_in.get(REPORT, params={"course_id": "1"}).status_code == 400
