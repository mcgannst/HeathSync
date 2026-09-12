from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import text

from app.api.deps import CurrentUser, current_user, get_db, get_throttle
from app.api.schemas import LoginRequest, LoginResponse, UserOut
from app.db import Database
from app.security import LoginThrottle, hash_token, new_token
from app.users import USER_COLUMNS, LoginBlocked, authenticate

router = APIRouter(prefix="/api/v1", tags=["auth"])


@router.post("/auth/login", response_model=LoginResponse)
async def login(
    body: LoginRequest, db: Database = Depends(get_db), throttle: LoginThrottle = Depends(get_throttle)
) -> LoginResponse:
    async with db.write() as conn:
        try:
            user = await authenticate(conn, throttle, body.username, body.password)
        except LoginBlocked:
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many failed attempts. Try again in 15 minutes.")
        if user is None:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect username or password.")
        token = new_token()
        await conn.execute(
            text("INSERT INTO app_sessions (user_id, token_hash, device_name) VALUES (:user_id, :token_hash, :device)"),
            {"user_id": user["id"], "token_hash": hash_token(token), "device": body.device_name},
        )
    return LoginResponse(token=token, user=UserOut.model_validate(dict(user)))


@router.post("/auth/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(user: CurrentUser = Depends(current_user), db: Database = Depends(get_db)) -> None:
    async with db.write() as conn:
        await conn.execute(text("UPDATE app_sessions SET revoked_at = now() WHERE id = :id"), {"id": user.session_id})


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser = Depends(current_user), db: Database = Depends(get_db)) -> UserOut:
    async with db.write() as conn:
        row = (
            await conn.execute(text(f"SELECT {USER_COLUMNS} FROM users WHERE id = :id"), {"id": user.id})
        ).mappings().one()
    return UserOut.model_validate(dict(row))
