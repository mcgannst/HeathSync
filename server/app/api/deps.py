from dataclasses import dataclass

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import text

from app.db import Database
from app.security import LoginThrottle, hash_token

_bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True)
class CurrentUser:
    id: int
    username: str
    display_name: str
    is_admin: bool
    session_id: int


def get_db(request: Request) -> Database:
    return request.app.state.db


def get_throttle(request: Request) -> LoginThrottle:
    return request.app.state.login_throttle


async def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    db: Database = Depends(get_db),
) -> CurrentUser:
    """Resolves the iOS app's bearer token. Revoked sessions and disabled accounts are rejected."""
    if credentials is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not signed in", headers={"WWW-Authenticate": "Bearer"})
    async with db.write() as conn:
        row = (
            await conn.execute(
                text(
                    """
                    UPDATE app_sessions s SET last_used_at = now()
                    FROM users u
                    WHERE s.token_hash = :token_hash AND s.revoked_at IS NULL
                      AND u.id = s.user_id AND u.is_active
                    RETURNING s.id AS session_id, u.id, u.username, u.display_name, u.is_admin
                    """
                ),
                {"token_hash": hash_token(credentials.credentials)},
            )
        ).mappings().first()
    if row is None:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED, "Session expired. Sign in again.", headers={"WWW-Authenticate": "Bearer"}
        )
    return CurrentUser(**row)


async def admin_user(user: CurrentUser = Depends(current_user)) -> CurrentUser:
    if not user.is_admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only an admin can do this.")
    return user
