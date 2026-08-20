"""Example application endpoints.

Everything mounted here is behind `require_auth` (see app/main.py), so these are
the shape to copy when you add real pages: read the signed-in user from the
dependency, never from a request body.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.auth.dependencies import require_admin, require_auth
from app.auth.models import AppUser
from app.auth.users import list_users
from app.db.session import db_connection

router = APIRouter(tags=["pages"])


@router.get("/dashboard")
def dashboard(current_user: AppUser = Depends(require_auth)) -> dict[str, object]:
    return {
        "greeting": f"Welcome, {current_user.display_name}.",
        "role": current_user.role,
    }


@router.get("/admin/users")
def admin_users(_: AppUser = Depends(require_admin)) -> dict[str, object]:
    with db_connection() as conn:
        users = list_users(conn)
    return {"users": users}
