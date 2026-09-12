import uuid
from typing import Any

import httpx
from sqlalchemy import text

from app.security import hash_password

PASSWORD = "correct-horse-battery"


async def make_user(app: Any, username: str, *, is_admin: bool = False, display_name: str | None = None) -> int:
    async with app.state.db.write() as conn:
        return (
            await conn.execute(
                text(
                    """
                    INSERT INTO users (username, display_name, password_hash, is_admin)
                    VALUES (:username, :display_name, :password_hash, :is_admin) RETURNING id
                    """
                ),
                {
                    "username": username,
                    "display_name": display_name or username.title(),
                    "password_hash": hash_password(PASSWORD),
                    "is_admin": is_admin,
                },
            )
        ).scalar_one()


async def login(client: httpx.AsyncClient, username: str, password: str = PASSWORD) -> dict[str, str]:
    response = await client.post(
        "/api/v1/auth/login", json={"username": username, "password": password, "device_name": "Test iPhone"}
    )
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['token']}"}


def sample(**overrides: Any) -> dict[str, Any]:
    values = {
        "uuid": str(uuid.uuid4()),
        "type": "heartRate",
        "start": "2026-09-01T08:00:00-06:00",
        "end": "2026-09-01T08:00:00-06:00",
        "value": 62,
        "unit": "count/min",
        "source_name": "Apple Watch",
    }
    values.update(overrides)
    return values


def summary(day: str, metric: str, stat: str, value: float, unit: str) -> dict[str, Any]:
    return {"day": day, "metric": metric, "stat": stat, "value": value, "unit": unit}
