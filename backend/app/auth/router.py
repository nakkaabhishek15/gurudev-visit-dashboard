from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, EmailStr, Field

from app.auth.dependencies import clear_session_user, require_auth, set_session_user
from app.auth.models import AppUser
from app.auth.users import (
    AccountInactive,
    AccountLocked,
    InvalidCredentials,
    authenticate,
)

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=1024)


@router.post("/login")
def login(payload: LoginRequest, request: Request) -> dict[str, object]:
    try:
        user = authenticate(payload.email, payload.password)
    except AccountLocked as exc:
        # This does tell an attacker the address exists. Accepted: lockout is
        # already observable by hammering the endpoint, and users need to be told
        # why a correct password is being refused.
        raise HTTPException(
            status_code=status.HTTP_423_LOCKED,
            detail=f"Too many failed attempts. Try again after {exc.locked_until:%H:%M UTC}.",
        ) from exc
    except AccountInactive as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    except InvalidCredentials as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc

    set_session_user(request, user.app_user_id)
    return user.to_me_payload()


@router.get("/me")
def me(current_user: AppUser = Depends(require_auth)) -> dict[str, object]:
    return current_user.to_me_payload()


@router.post("/logout")
def logout(request: Request) -> dict[str, str]:
    clear_session_user(request)
    request.session.clear()
    return {"status": "ok"}
