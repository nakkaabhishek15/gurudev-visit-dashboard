from __future__ import annotations

from functools import lru_cache

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

MIN_PASSWORD_LENGTH = 12

_hasher = PasswordHasher()


class WeakPasswordError(ValueError):
    """Raised when a candidate password fails the minimum policy."""


def validate_password(password: str) -> None:
    if len(password) < MIN_PASSWORD_LENGTH:
        raise WeakPasswordError(f"Password must be at least {MIN_PASSWORD_LENGTH} characters.")
    if password.strip() != password:
        raise WeakPasswordError("Password must not start or end with whitespace.")


def hash_password(password: str) -> str:
    validate_password(password)
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        _hasher.verify(password_hash, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False
    return True


def needs_rehash(password_hash: str) -> bool:
    try:
        return _hasher.check_needs_rehash(password_hash)
    except InvalidHashError:
        return True


@lru_cache(maxsize=1)
def _decoy_hash() -> str:
    return _hasher.hash("unused-timing-decoy-password")


def dummy_verify(password: str) -> None:
    """Burn one real verification.

    Called when no account matches the submitted email so that an unknown email
    costs the same wall-clock time as a wrong password. A hardcoded hash string
    would not work here: argon2 rejects a malformed hash immediately and the
    call returns far too fast to hide the difference.
    """
    verify_password(_decoy_hash(), password)
