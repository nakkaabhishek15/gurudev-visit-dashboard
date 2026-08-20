from __future__ import annotations

ADMIN_ROLE = "admin"
STAFF_ROLE = "staff"
DEFAULT_ROLE = STAFF_ROLE

# Most specific first. primary_role() returns the strongest role a user holds.
ROLE_PRECEDENCE = [ADMIN_ROLE, STAFF_ROLE]
KNOWN_ROLES = set(ROLE_PRECEDENCE)


def primary_role(roles: list[str]) -> str:
    for role in ROLE_PRECEDENCE:
        if role in roles:
            return role
    return DEFAULT_ROLE


def normalize_roles(roles: list[str] | None) -> list[str]:
    if not roles:
        return [DEFAULT_ROLE]
    cleaned = sorted({role.strip().lower() for role in roles if role.strip()})
    unknown = [role for role in cleaned if role not in KNOWN_ROLES]
    if unknown:
        raise ValueError(f"Unknown role(s): {', '.join(unknown)}. Known roles: {', '.join(sorted(KNOWN_ROLES))}.")
    return cleaned or [DEFAULT_ROLE]
