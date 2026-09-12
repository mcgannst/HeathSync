import hashlib
import secrets
import time

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError

_hasher = PasswordHasher()
# Verified against when the username doesn't exist, so a login takes the same time either way.
_DUMMY_HASH = _hasher.hash(secrets.token_urlsafe(16))

MIN_PASSWORD_LENGTH = 10


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str | None, password: str) -> bool:
    try:
        matched = _hasher.verify(password_hash or _DUMMY_HASH, password)
    except (VerificationError, InvalidHashError):
        return False
    return matched and password_hash is not None


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    """Tokens are high-entropy random strings, so a plain SHA-256 is enough to store them safely."""
    return hashlib.sha256(token.encode()).hexdigest()


class LoginThrottle:
    """Refuses logins for a username after repeated failures.

    Kept in memory, which is correct because the server runs as a single process.
    """

    def __init__(self, max_failures: int = 5, window_seconds: int = 15 * 60):
        self.max_failures = max_failures
        self.window_seconds = window_seconds
        self._failures: dict[str, list[float]] = {}

    def is_blocked(self, username: str) -> bool:
        return len(self._recent(username)) >= self.max_failures

    def record_failure(self, username: str) -> None:
        self._recent(username).append(time.monotonic())

    def reset(self, username: str) -> None:
        self._failures.pop(username.lower(), None)

    def _recent(self, username: str) -> list[float]:
        cutoff = time.monotonic() - self.window_seconds
        failures = [t for t in self._failures.get(username.lower(), []) if t > cutoff]
        self._failures[username.lower()] = failures
        return failures
