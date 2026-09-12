from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, create_async_engine

from app.config import Settings


class Database:
    """Two connection pools with different Postgres roles.

    `write()` uses the API role. `read_as()` uses the read-only MCP role and scopes the transaction to one
    user, so row security in the database (db/grants.sql) enforces that tools only see that user's data.
    """

    def __init__(self, settings: Settings):
        self._app = create_async_engine(settings.database_url, pool_pre_ping=True, pool_size=5, max_overflow=5)
        self._mcp = create_async_engine(settings.mcp_database_url, pool_pre_ping=True, pool_size=5, max_overflow=5)

    @asynccontextmanager
    async def write(self) -> AsyncIterator[AsyncConnection]:
        async with self._app.begin() as conn:
            yield conn

    @asynccontextmanager
    async def read_as(self, user_id: int) -> AsyncIterator[AsyncConnection]:
        async with self._mcp.begin() as conn:
            # is_local=true: the setting ends with the transaction, so a pooled connection never keeps it.
            await conn.execute(
                text("SELECT set_config('healthsync.user_id', :user_id, true)"),
                {"user_id": str(user_id)},
            )
            yield conn

    async def dispose(self) -> None:
        await self._app.dispose()
        await self._mcp.dispose()
