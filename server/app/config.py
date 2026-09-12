from functools import lru_cache
from urllib.parse import urlparse

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Read from environment variables; the container gets them from deploy/.env.<env>."""

    model_config = SettingsConfigDict(extra="ignore")

    # Read-write role: iOS app API, accounts and OAuth.
    database_url: str
    # Read-only role with per-user row security: MCP tools only.
    mcp_database_url: str
    # Public origin, e.g. https://healthsync.sunspinner.ca. The OAuth issuer and MCP resource derive from it.
    public_url: str

    access_token_ttl_seconds: int = 60 * 60
    refresh_token_ttl_seconds: int = 60 * 60 * 24 * 30
    log_level: str = "INFO"

    @property
    def issuer_url(self) -> str:
        return self.public_url.rstrip("/")

    @property
    def mcp_url(self) -> str:
        return f"{self.issuer_url}/mcp"

    @property
    def public_host(self) -> str:
        return urlparse(self.public_url).netloc


@lru_cache
def get_settings() -> Settings:
    return Settings()
