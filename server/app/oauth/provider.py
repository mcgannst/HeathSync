"""OAuth 2.1 authorization server for the MCP connector, stored in Postgres.

Flow: claude.ai registers itself (/register), sends the person to /authorize, which this provider turns into
a pending request and redirects to the HealthSync login page. After a successful sign-in the login page calls
`complete_authorization`, which issues a one-time code and sends the browser back to Claude. Codes and tokens
are stored as SHA-256 hashes, and every token is tied to a user ID that MCP tools use to scope their queries.
"""

from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import urlencode
from uuid import uuid4

from mcp.server.auth.provider import (
    AccessToken,
    AuthorizationCode,
    AuthorizationParams,
    OAuthAuthorizationServerProvider,
    RefreshToken,
    TokenError,
    construct_redirect_uri,
)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from app.config import Settings
from app.db import Database
from app.security import hash_token, new_token

SCOPE = "health:read"
PENDING_TTL = timedelta(minutes=10)
CODE_TTL = timedelta(minutes=5)


class PendingAuthorization(BaseModel):
    client_name: str | None
    params: AuthorizationParams


class HealthSyncOAuthProvider(OAuthAuthorizationServerProvider[AuthorizationCode, RefreshToken, AccessToken]):
    def __init__(self, db: Database, settings: Settings):
        self.db = db
        self.settings = settings

    # Clients

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        async with self.db.write() as conn:
            info = (
                await conn.execute(text("SELECT client_info FROM oauth_clients WHERE client_id = :id"), {"id": client_id})
            ).scalar_one_or_none()
        return OAuthClientInformationFull.model_validate(info) if info else None

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        async with self.db.write() as conn:
            await conn.execute(
                text(
                    """
                    INSERT INTO oauth_clients (client_id, client_info) VALUES (:id, CAST(:info AS jsonb))
                    ON CONFLICT (client_id) DO UPDATE SET client_info = EXCLUDED.client_info
                    """
                ),
                {"id": client_info.client_id, "info": client_info.model_dump_json()},
            )

    # Authorization: /authorize → login page → code

    async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
        request_id = new_token()
        async with self.db.write() as conn:
            await conn.execute(text("DELETE FROM oauth_pending_authorizations WHERE expires_at < now()"))
            await conn.execute(
                text(
                    """
                    INSERT INTO oauth_pending_authorizations (id, client_id, params, expires_at)
                    VALUES (:id, :client_id, CAST(:params AS jsonb), :expires_at)
                    """
                ),
                {
                    "id": request_id,
                    "client_id": client.client_id,
                    "params": params.model_dump_json(),
                    "expires_at": _now() + PENDING_TTL,
                },
            )
        return f"{self.settings.issuer_url}/oauth/login?{urlencode({'request': request_id})}"

    async def pending_authorization(self, request_id: str) -> PendingAuthorization | None:
        async with self.db.write() as conn:
            row = (
                await conn.execute(
                    text(
                        """
                        SELECT p.params, c.client_info->>'client_name' AS client_name
                        FROM oauth_pending_authorizations p JOIN oauth_clients c USING (client_id)
                        WHERE p.id = :id AND p.expires_at > now()
                        """
                    ),
                    {"id": request_id},
                )
            ).mappings().first()
        return PendingAuthorization(client_name=row["client_name"], params=row["params"]) if row else None

    async def complete_authorization(self, request_id: str, user_id: int) -> str | None:
        """Issues an authorization code for a signed-in user. Returns the URL to send the browser back to,
        or None if the request expired or was already used."""
        async with self.db.write() as conn:
            row = (
                await conn.execute(
                    text(
                        """
                        DELETE FROM oauth_pending_authorizations WHERE id = :id AND expires_at > now()
                        RETURNING client_id, params
                        """
                    ),
                    {"id": request_id},
                )
            ).mappings().first()
            if row is None:
                return None
            params = AuthorizationParams.model_validate(row["params"])
            code = new_token()
            authorization = AuthorizationCode(
                code=code,
                scopes=params.scopes or [SCOPE],
                expires_at=(_now() + CODE_TTL).timestamp(),
                client_id=row["client_id"],
                code_challenge=params.code_challenge,
                redirect_uri=params.redirect_uri,
                redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
                resource=params.resource,
                subject=str(user_id),
            )
            await conn.execute(
                text(
                    """
                    INSERT INTO oauth_codes (code_hash, client_id, user_id, params, expires_at)
                    VALUES (:code_hash, :client_id, :user_id, CAST(:params AS jsonb), :expires_at)
                    """
                ),
                {
                    "code_hash": hash_token(code),
                    "client_id": row["client_id"],
                    "user_id": user_id,
                    "params": authorization.model_dump_json(exclude={"code"}),
                    "expires_at": _now() + CODE_TTL,
                },
            )
        return construct_redirect_uri(str(params.redirect_uri), code=code, state=params.state)

    async def load_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: str
    ) -> AuthorizationCode | None:
        async with self.db.write() as conn:
            params = (
                await conn.execute(
                    text(
                        """
                        SELECT params FROM oauth_codes
                        WHERE code_hash = :code_hash AND client_id = :client_id AND expires_at > now()
                        """
                    ),
                    {"code_hash": hash_token(authorization_code), "client_id": client.client_id},
                )
            ).scalar_one_or_none()
        return AuthorizationCode.model_validate({**params, "code": authorization_code}) if params else None

    async def exchange_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: AuthorizationCode
    ) -> OAuthToken:
        async with self.db.write() as conn:
            used = (
                await conn.execute(
                    text("DELETE FROM oauth_codes WHERE code_hash = :code_hash RETURNING user_id"),
                    {"code_hash": hash_token(authorization_code.code)},
                )
            ).scalar_one_or_none()
            if used is None:
                raise TokenError("invalid_grant", "Authorization code was already used.")
            return await self._issue(conn, client.client_id, used, authorization_code.scopes)

    # Tokens

    async def load_refresh_token(self, client: OAuthClientInformationFull, refresh_token: str) -> RefreshToken | None:
        row = await self._load_token(refresh_token, "refresh", client.client_id)
        if row is None:
            return None
        return RefreshToken(
            token=refresh_token,
            client_id=row["client_id"],
            scopes=list(row["scopes"]),
            expires_at=int(row["expires_at"].timestamp()),
            resource=self.settings.mcp_url,
            subject=str(row["user_id"]),
        )

    async def exchange_refresh_token(
        self, client: OAuthClientInformationFull, refresh_token: RefreshToken, scopes: list[str]
    ) -> OAuthToken:
        async with self.db.write() as conn:
            # Rotation: the old pair is revoked in the same statement that proves it was still valid,
            # so two concurrent refreshes can't both succeed.
            revoked = (
                await conn.execute(
                    text(
                        """
                        UPDATE oauth_tokens SET revoked_at = now()
                        WHERE revoked_at IS NULL
                          AND grant_id = (SELECT grant_id FROM oauth_tokens WHERE token_hash = :token_hash AND revoked_at IS NULL)
                        RETURNING token_hash
                        """
                    ),
                    {"token_hash": hash_token(refresh_token.token)},
                )
            ).first()
            if revoked is None:
                raise TokenError("invalid_grant", "Refresh token is no longer valid.")
            return await self._issue(
                conn, client.client_id, int(refresh_token.subject or 0), scopes or refresh_token.scopes
            )

    async def load_access_token(self, token: str) -> AccessToken | None:
        row = await self._load_token(token, "access")
        if row is None:
            return None
        return AccessToken(
            token=token,
            client_id=row["client_id"],
            scopes=list(row["scopes"]),
            expires_at=int(row["expires_at"].timestamp()),
            resource=self.settings.mcp_url,
            subject=str(row["user_id"]),
        )

    async def revoke_token(self, token: AccessToken | RefreshToken) -> None:
        async with self.db.write() as conn:
            await conn.execute(
                text(
                    """
                    UPDATE oauth_tokens SET revoked_at = now()
                    WHERE revoked_at IS NULL
                      AND grant_id = (SELECT grant_id FROM oauth_tokens WHERE token_hash = :token_hash)
                    """
                ),
                {"token_hash": hash_token(token.token)},
            )

    async def _load_token(self, token: str, kind: str, client_id: str | None = None) -> Any:
        async with self.db.write() as conn:
            return (
                await conn.execute(
                    text(
                        """
                        SELECT t.client_id, t.user_id, t.scopes, t.expires_at
                        FROM oauth_tokens t JOIN users u ON u.id = t.user_id
                        WHERE t.token_hash = :token_hash AND t.kind = :kind
                          AND t.revoked_at IS NULL AND t.expires_at > now() AND u.is_active
                          AND (CAST(:client_id AS text) IS NULL OR t.client_id = :client_id)
                        """
                    ),
                    {"token_hash": hash_token(token), "kind": kind, "client_id": client_id},
                )
            ).mappings().first()

    async def _issue(self, conn: AsyncConnection, client_id: str, user_id: int, scopes: list[str]) -> OAuthToken:
        access_token, refresh_token = new_token(), new_token()
        grant_id = uuid4()
        now = _now()
        base = {"grant_id": grant_id, "client_id": client_id, "user_id": user_id, "scopes": scopes, "resource": self.settings.mcp_url}
        await conn.execute(
            text(
                """
                INSERT INTO oauth_tokens (token_hash, kind, grant_id, client_id, user_id, scopes, resource, expires_at)
                VALUES (:token_hash, :kind, :grant_id, :client_id, :user_id, :scopes, :resource, :expires_at)
                """
            ),
            [
                {
                    **base,
                    "token_hash": hash_token(access_token),
                    "kind": "access",
                    "expires_at": now + timedelta(seconds=self.settings.access_token_ttl_seconds),
                },
                {
                    **base,
                    "token_hash": hash_token(refresh_token),
                    "kind": "refresh",
                    "expires_at": now + timedelta(seconds=self.settings.refresh_token_ttl_seconds),
                },
            ],
        )
        await conn.execute(text("DELETE FROM oauth_tokens WHERE expires_at < now() - interval '7 days'"))
        await conn.execute(text("DELETE FROM oauth_codes WHERE expires_at < now()"))
        return OAuthToken(
            access_token=access_token,
            expires_in=self.settings.access_token_ttl_seconds,
            scope=" ".join(scopes),
            refresh_token=refresh_token,
        )


def _now() -> datetime:
    return datetime.now(UTC)
