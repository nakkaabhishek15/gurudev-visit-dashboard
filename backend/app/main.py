from __future__ import annotations

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.sessions import SessionMiddleware

from app.api.pages import router as pages_router
from app.api.reports import router as reports_router
from app.auth.dependencies import require_auth
from app.auth.router import router as auth_router
from app.db.session import db_connection
from app.settings import get_settings


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="Gurudev Visit Dashboard")

    app.add_middleware(
        SessionMiddleware,
        secret_key=settings.session_secret,
        session_cookie=settings.session_cookie_name,
        max_age=settings.session_max_age_seconds,
        same_site="lax",
        https_only=settings.auth_cookie_secure,
    )
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list(),
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # The ALB target group health check hits /health; CloudFront forwards /api/*.
    @app.get("/health")
    @app.get("/api/health")
    def health() -> dict[str, object]:
        database = "ok"
        try:
            with db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1 AS ok")
                    cur.fetchone()
        except Exception as exc:
            database = f"error: {exc}"
        return {"app": "ok", "database": database}

    app.include_router(auth_router, prefix="/api")

    protected = [Depends(require_auth)]
    app.include_router(pages_router, prefix="/api", dependencies=protected)
    app.include_router(reports_router, prefix="/api", dependencies=protected)
    return app


app = create_app()
