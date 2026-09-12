"""Tests run against the local Docker Postgres set up by scripts/db.sh, using the same roles, grants and row
security as the real environments:

    docker run -d --name healthsync-pg-local -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:14
    PGADMIN_URL=postgresql://postgres:postgres@localhost:55432/postgres bash scripts/db.sh local
"""

import os
from pathlib import Path

import pytest

ENV_FILE = Path(__file__).resolve().parents[2] / "deploy" / ".env.local"
if not ENV_FILE.exists():
    pytest.exit(f"{ENV_FILE} is missing. Set up the local database first (see tests/conftest.py).", returncode=2)
for line in ENV_FILE.read_text().splitlines():
    key, separator, value = line.partition("=")
    if separator:
        os.environ[key] = value
os.environ["PUBLIC_URL"] = "http://localhost"

import httpx  # noqa: E402
from asgi_lifespan import LifespanManager  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app.config import Settings  # noqa: E402
from app.main import create_app  # noqa: E402

TABLES = (
    "oauth_tokens",
    "oauth_codes",
    "oauth_pending_authorizations",
    "oauth_clients",
    "app_sessions",
    "daily_summaries",
    "workouts",
    "samples",
    "users",
)


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture
async def app():
    application = create_app(Settings())
    async with LifespanManager(application):
        async with application.state.db.write() as conn:
            for table in TABLES:
                await conn.execute(text(f"DELETE FROM {table}"))
        yield application


@pytest.fixture
async def client(app):
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://localhost") as http:
        yield http
