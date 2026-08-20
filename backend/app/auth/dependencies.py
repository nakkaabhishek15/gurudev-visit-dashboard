from __future__ import annotations

from uuid import UUID

from fastapi import Depends, HTTPException, Request, status

from app.auth.models import AppUser
from app.auth.roles import ADMIN_ROLE
from app.auth.users import load_app_user
from app.db.session import db_connection

SESSION_USER_ID_KEY = "app_user_id"


def get_session_user_id(request: Request) -> UUID | None:
    raw_user_id = request.session.get(SESSION_USER_ID_KEY)
    if not raw_user_id:
        return None
    try:
        return UUID(str(raw_user_id))
    except ValueError:
        return None


def set_session_user(request: Request, app_user_id: UUID) -> None:
    # Drop any pre-login session state so a fixated cookie cannot survive login.
    request.session.clear()
    request.session[SESSION_USER_ID_KEY] = str(app_user_id)


def clear_session_user(request: Request) -> None:
    request.session.pop(SESSION_USER_ID_KEY, None)


def get_current_user(request: Request) -> AppUser:
    app_user_id = get_session_user_id(request)
    if app_user_id is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authentication required.")

    with db_connection() as conn:
        user = load_app_user(conn, app_user_id)

    # The account was deleted or deactivated while the cookie was still valid.
    if user is None:
        clear_session_user(request)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authentication required.")
    return user


def require_auth(current_user: AppUser = Depends(get_current_user)) -> AppUser:
    return current_user


def require_admin(current_user: AppUser = Depends(get_current_user)) -> AppUser:
    if not current_user.has_role(ADMIN_ROLE):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Administrator access required.")
    return current_user
