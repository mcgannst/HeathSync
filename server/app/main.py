import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from mcp.server.transport_security import TransportSecuritySettings
from sqlalchemy import text

from app.api import admin, auth, sync
from app.config import Settings, get_settings
from app.db import Database
from app.mcp_server import build_mcp
from app.oauth import login
from app.oauth.provider import HealthSyncOAuthProvider
from app.security import LoginThrottle


def create_app(settings: Settings | None = None) -> FastAPI:
    """One process serves the iOS app API (/api/v1), the OAuth sign-in (/authorize, /token, /oauth/login...)
    and the MCP endpoint (/mcp). Run with: uvicorn --factory app.main:create_app"""
    settings = settings or get_settings()
    _configure_logging(settings.log_level)

    db = Database(settings)
    provider = HealthSyncOAuthProvider(db, settings)
    mcp = build_mcp(db, settings, provider)
    mcp_app = mcp.streamable_http_app(
        streamable_http_path="/mcp",
        # Stateless: each request carries its own token, so no session can outlive a revoked one.
        stateless_http=True,
        json_response=True,
        host="0.0.0.0",
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=[settings.public_host, "localhost:*", "127.0.0.1:*"],
            allowed_origins=[settings.issuer_url, "https://claude.ai", "http://localhost:*"],
        ),
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        # Mounted apps don't get lifespan events, so the MCP session manager is started here.
        async with mcp.session_manager.run():
            yield
        await db.dispose()

    app = FastAPI(title="HealthSync", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings
    app.state.db = db
    app.state.oauth_provider = provider
    app.state.login_throttle = LoginThrottle()

    app.include_router(auth.router)
    app.include_router(sync.router)
    app.include_router(admin.router)
    app.include_router(login.router)

    @app.get("/healthz", include_in_schema=False)
    async def healthz() -> dict[str, str]:
        async with db.write() as conn:
            await conn.execute(text("SELECT 1"))
        return {"status": "ok"}

    # Last, so the API routes above take precedence. Provides /mcp, the OAuth endpoints and metadata.
    app.mount("/", mcp_app)
    return app


def _configure_logging(level: str) -> None:
    """Every log line starts with the local time and its offset (the container's TZ)."""
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s", "%Y-%m-%d %H:%M:%S %z")
    logging.basicConfig(level=level)
    # uvicorn sets up its own handlers before the app factory runs, so restyle those too.
    for name in ("", "uvicorn", "uvicorn.error", "uvicorn.access"):
        for handler in logging.getLogger(name).handlers:
            handler.setFormatter(formatter)
