from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_env: str = "local"
    database_url: str = ""

    # Read-only connection to the AOLF warehouse (raw_data.retreat_guru_*).
    # Falls back to database_url when unset, which is what production does when
    # the app schema and the warehouse live on the same instance. Locally they
    # differ: the app runs on the compose Postgres, the warehouse is reached
    # over the SSM tunnel.
    warehouse_database_url: str = ""

    session_secret: str = "local-dev-session-secret-change-me"
    session_cookie_name: str = "gurudev_session"
    session_max_age_seconds: int = 60 * 60 * 12
    auth_cookie_secure: bool = False

    # Failed-login lockout. Set max_failed_logins to 0 to disable lockout entirely.
    max_failed_logins: int = 10
    lockout_minutes: int = 15

    # Retreat Guru programs this deployment is allowed to report on. Enforced
    # server-side: a signed-in user cannot widen the scope by editing the query
    # string, so no other course in the warehouse is reachable.
    gurudev_course_ids: str = "4521,4522"

    cors_allowed_origins: str = "http://127.0.0.1:5173,http://localhost:5173"

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_allowed_origins.split(",") if origin.strip()]

    def course_id_allowlist(self) -> list[str]:
        return [c.strip() for c in self.gurudev_course_ids.split(",") if c.strip()]

    def warehouse_url(self) -> str:
        return self.warehouse_database_url or self.database_url


@lru_cache
def get_settings() -> Settings:
    return Settings()
