from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

from app.auth.roles import primary_role


@dataclass(frozen=True)
class AppUser:
    app_user_id: UUID
    email: str
    display_name: str
    roles: list[str]

    @property
    def role(self) -> str:
        return primary_role(self.roles)

    def has_role(self, role: str) -> bool:
        return role in self.roles

    def to_me_payload(self) -> dict[str, object]:
        return {
            "app_user_id": str(self.app_user_id),
            "email": self.email,
            "display_name": self.display_name,
            "roles": self.roles,
            "role": self.role,
        }
