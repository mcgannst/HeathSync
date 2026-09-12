from collections.abc import Mapping
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from app.security import LoginThrottle, verify_password

USER_COLUMNS = "id, username, display_name, is_admin, is_active, time_zone, last_sync_at, created_at"


class LoginBlocked(Exception):
    """Too many recent failed attempts for this username."""


async def authenticate(
    conn: AsyncConnection, throttle: LoginThrottle, username: str, password: str
) -> Mapping[str, Any] | None:
    """Returns the user row for valid credentials on an active account, otherwise None."""
    username = username.strip()
    if throttle.is_blocked(username):
        raise LoginBlocked
    row = (
        await conn.execute(
            text(f"SELECT {USER_COLUMNS}, password_hash FROM users WHERE lower(username) = lower(:username)"),
            {"username": username},
        )
    ).mappings().first()
    valid = verify_password(row["password_hash"] if row else None, password)
    if not valid or row is None or not row["is_active"]:
        throttle.record_failure(username)
        return None
    throttle.reset(username)
    return row
