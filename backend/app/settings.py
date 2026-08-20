from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_env: str = "local"
    database_url: str = ""

    session_secret: str = "local-dev-session-secret-change-me"
    session_cookie_name: str = "gurudev_session"
    session_max_age_seconds: int = 60 * 60 * 12
    auth_cookie_secure: bool = False

    # Failed-login lockout. Set max_failed_logins to 0 to disable lockout entirely.
    max_failed_logins: int = 10
    lockout_minutes: int = 15

    cors_allowed_origins: str = "http://127.0.0.1:5173,http://localhost:5173"

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_allowed_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
