from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import text

from app.api.deps import CurrentUser, admin_user, get_db
from app.api.schemas import CreateUser, UpdateUser, UserOut
from app.db import Database
from app.security import hash_password
from app.users import USER_COLUMNS

router = APIRouter(prefix="/api/v1/admin/users", tags=["admin"])


@router.get("", response_model=list[UserOut])
async def list_users(_: CurrentUser = Depends(admin_user), db: Database = Depends(get_db)) -> list[UserOut]:
    async with db.write() as conn:
        rows = (await conn.execute(text(f"SELECT {USER_COLUMNS} FROM users ORDER BY lower(username)"))).mappings()
        return [UserOut.model_validate(dict(row)) for row in rows]


@router.post("", response_model=UserOut, status_code=status.HTTP_201_CREATED)
async def create_user(
    body: CreateUser, _: CurrentUser = Depends(admin_user), db: Database = Depends(get_db)
) -> UserOut:
    async with db.write() as conn:
        taken = (
            await conn.execute(
                text("SELECT 1 FROM users WHERE lower(username) = lower(:username)"), {"username": body.username}
            )
        ).first()
        if taken:
            raise HTTPException(status.HTTP_409_CONFLICT, f"The username {body.username} is already taken.")
        row = (
            await conn.execute(
                text(
                    f"""
                    INSERT INTO users (username, display_name, password_hash, is_admin)
                    VALUES (:username, :display_name, :password_hash, :is_admin)
                    RETURNING {USER_COLUMNS}
                    """
                ),
                {
                    "username": body.username,
                    "display_name": body.display_name,
                    "password_hash": hash_password(body.password),
                    "is_admin": body.is_admin,
                },
            )
        ).mappings().one()
    return UserOut.model_validate(dict(row))


@router.patch("/{user_id}", response_model=UserOut)
async def update_user(
    user_id: int, body: UpdateUser, admin: CurrentUser = Depends(admin_user), db: Database = Depends(get_db)
) -> UserOut:
    if user_id == admin.id and (body.is_active is False or body.is_admin is False):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "You can't disable your own account or remove your own admin access.")

    changes: dict[str, object] = {}
    if body.display_name is not None:
        changes["display_name"] = body.display_name
    if body.password is not None:
        changes["password_hash"] = hash_password(body.password)
    if body.is_active is not None:
        changes["is_active"] = body.is_active
    if body.is_admin is not None:
        changes["is_admin"] = body.is_admin

    async with db.write() as conn:
        assignments = ", ".join(f"{column} = :{column}" for column in changes)
        row = (
            await conn.execute(
                text(
                    f"UPDATE users SET {assignments}{', ' if assignments else ''}updated_at = now() "
                    f"WHERE id = :user_id RETURNING {USER_COLUMNS}"
                ),
                {**changes, "user_id": user_id},
            )
        ).mappings().first()
        if row is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "No such user.")

        # A disabled account or a reset password signs that person out everywhere: the app and Claude.
        # An admin changing their own password stays signed in on the device they're using.
        if body.is_active is False or body.password is not None:
            await conn.execute(
                text("UPDATE app_sessions SET revoked_at = now() WHERE user_id = :user_id AND revoked_at IS NULL AND id <> :keep"),
                {"user_id": user_id, "keep": admin.session_id},
            )
            await conn.execute(
                text("UPDATE oauth_tokens SET revoked_at = now() WHERE user_id = :user_id AND revoked_at IS NULL"),
                {"user_id": user_id},
            )
    return UserOut.model_validate(dict(row))
