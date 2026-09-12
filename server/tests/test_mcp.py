import base64
import hashlib
import secrets
from typing import Any
from urllib.parse import parse_qs, urlparse

import httpx2
import pytest
from mcp import Client
from mcp.client.streamable_http import streamable_http_client
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from tests.helpers import PASSWORD, login, make_user, sample, summary

pytestmark = pytest.mark.anyio

REDIRECT_URI = "https://claude.ai/api/mcp/auth_callback"
MCP_URL = "http://localhost/mcp"


async def register_client(client) -> dict[str, Any]:
    response = await client.post(
        "/register",
        json={
            "client_name": "Claude",
            "redirect_uris": [REDIRECT_URI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "client_secret_post",
            "scope": "health:read",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


async def start_authorization(client, registration: dict[str, Any]) -> tuple[str, str]:
    """Returns the login page URL and the PKCE verifier."""
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    response = await client.get(
        "/authorize",
        params={
            "response_type": "code",
            "client_id": registration["client_id"],
            "redirect_uri": REDIRECT_URI,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": "state-123",
            "scope": "health:read",
            "resource": MCP_URL,
        },
    )
    assert response.status_code in (302, 307), response.text
    return response.headers["location"], verifier


async def connect_claude(client, username: str) -> dict[str, Any]:
    """The OAuth flow claude.ai performs: register, authorize with PKCE, sign in, exchange the code."""
    registration = await register_client(client)
    login_url, verifier = await start_authorization(client, registration)
    request_id = parse_qs(urlparse(login_url).query)["request"][0]

    page = await client.get(login_url)
    assert page.status_code == 200
    assert "read-only access" in page.text

    signed_in = await client.post(
        "/oauth/login", data={"request": request_id, "username": username, "password": PASSWORD}
    )
    assert signed_in.status_code == 302, signed_in.text
    callback = urlparse(signed_in.headers["location"])
    assert f"{callback.scheme}://{callback.netloc}{callback.path}" == REDIRECT_URI
    query = parse_qs(callback.query)
    assert query["state"] == ["state-123"]

    token = await client.post(
        "/token",
        data={
            "grant_type": "authorization_code",
            "code": query["code"][0],
            "redirect_uri": REDIRECT_URI,
            "client_id": registration["client_id"],
            "client_secret": registration["client_secret"],
            "code_verifier": verifier,
            "resource": MCP_URL,
        },
    )
    assert token.status_code == 200, token.text
    return {**token.json(), **registration}


async def call_tool(app, access_token: str, name: str, arguments: dict[str, Any] | None = None) -> Any:
    http = httpx2.AsyncClient(
        transport=httpx2.ASGITransport(app=app),
        base_url="http://localhost",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    async with http, Client(streamable_http_client(MCP_URL, http_client=http), cache=None) as mcp_client:
        result = await mcp_client.call_tool(name, arguments or {})
        tools = await mcp_client.list_tools()
    assert not result.is_error, result
    return result.structured_content, tools


async def seed(app, client, username: str, steps: float, heart_rate: float) -> None:
    headers = await login(client, username)
    await client.post(
        "/api/v1/sync/daily",
        json={
            "time_zone": "America/Edmonton",
            "summaries": [
                summary("2026-08-01", "stepCount", "sum", steps, "count"),
                summary("2026-09-01", "stepCount", "sum", steps * 2, "count"),
                summary("2026-09-01", "sleepAnalysis", "asleep", 7.5, "hr"),
                summary("2026-09-01", "sleepAnalysis", "wake_time", 1788271200, "unix_s"),
            ],
        },
        headers=headers,
    )
    await client.post(
        "/api/v1/sync/samples",
        json={"samples": [sample(value=heart_rate), sample(value=heart_rate + 10, start="2026-09-01T08:30:00-06:00", end="2026-09-01T08:30:00-06:00")]},
        headers=headers,
    )


async def test_discovery_metadata_and_unauthenticated_requests(client):
    server_metadata = (await client.get("/.well-known/oauth-authorization-server")).json()
    assert server_metadata["registration_endpoint"] == "http://localhost/register"
    resource_metadata = (await client.get("/.well-known/oauth-protected-resource/mcp")).json()
    assert resource_metadata["resource"] == MCP_URL

    response = await client.post("/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    assert response.status_code == 401
    assert "resource_metadata" in response.headers["www-authenticate"]


async def test_claude_sees_only_the_signed_in_persons_data(app, client):
    await make_user(app, "stephen", display_name="Stephen")
    await make_user(app, "dee", display_name="Dee")
    await seed(app, client, "stephen", steps=10000, heart_rate=60)
    await seed(app, client, "dee", steps=5000, heart_rate=80)
    token = await connect_claude(client, "dee")

    overview, tools = await call_tool(app, token["access_token"], "get_overview")
    assert overview["name"] == "Dee"
    assert {row["type"]: row["count"] for row in overview["samples"]} == {"heartRate": 2}
    assert all(tool.annotations.read_only_hint for tool in tools.tools)

    daily, _ = await call_tool(
        app, token["access_token"], "get_daily_summaries",
        {"start_date": "2026-09-01", "end_date": "2026-09-01", "metrics": ["stepCount"]},
    )
    assert daily["days"] == [{"date": "2026-09-01", "stepCount.sum": 10000}]

    readings, _ = await call_tool(
        app, token["access_token"], "get_samples", {"metric": "heartRate", "start": "2026-09-01", "end": "2026-09-01"}
    )
    assert [reading["value"] for reading in readings["samples"]] == [80, 90]

    hourly, _ = await call_tool(
        app, token["access_token"], "get_samples",
        {"metric": "heartRate", "start": "2026-09-01", "end": "2026-09-01", "bucket": "hour"},
    )
    assert hourly["buckets"][0]["avg"] == 85
    assert hourly["buckets"][0]["start"] == "2026-09-01T08:00-06:00"

    sleep, _ = await call_tool(app, token["access_token"], "get_sleep", {"start_date": "2026-09-01", "end_date": "2026-09-01"})
    assert sleep["nights"][0]["asleep_hours"] == 7.5
    assert sleep["nights"][0]["wake_time"] == "2026-09-01T08:00-06:00"

    comparison, _ = await call_tool(
        app, token["access_token"], "compare_periods",
        {
            "metrics": ["stepCount"],
            "period_a_start": "2026-08-01", "period_a_end": "2026-08-31",
            "period_b_start": "2026-09-01", "period_b_end": "2026-09-30",
        },
    )
    assert comparison["comparisons"][0]["percent_change"] == 100.0


async def test_wrong_password_on_the_login_page(app, client):
    await make_user(app, "stephen")
    registration = await register_client(client)
    login_url, _ = await start_authorization(client, registration)
    request_id = parse_qs(urlparse(login_url).query)["request"][0]

    response = await client.post("/oauth/login", data={"request": request_id, "username": "stephen", "password": "nope"})
    assert response.status_code == 401
    assert "Incorrect username or password" in response.text
    assert response.headers["x-frame-options"] == "DENY"

    unknown = await client.get("/oauth/login", params={"request": "not-a-request"})
    assert unknown.status_code == 400


async def test_refresh_tokens_rotate(app, client):
    await make_user(app, "stephen")
    token = await connect_claude(client, "stephen")
    refresh = {
        "grant_type": "refresh_token",
        "refresh_token": token["refresh_token"],
        "client_id": token["client_id"],
        "client_secret": token["client_secret"],
    }

    renewed = await client.post("/token", data=refresh)
    assert renewed.status_code == 200, renewed.text
    reused = await client.post("/token", data=refresh)
    assert reused.status_code == 400

    old_access = await client.post(
        "/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        headers={"Authorization": f"Bearer {token['access_token']}"},
    )
    assert old_access.status_code == 401
    await call_tool(app, renewed.json()["access_token"], "get_overview")


async def test_disabling_an_account_cuts_off_claude(app, client):
    user_id = await make_user(app, "twyla")
    token = await connect_claude(client, "twyla")
    async with app.state.db.write() as conn:
        await conn.execute(text("UPDATE users SET is_active = false WHERE id = :id"), {"id": user_id})

    response = await client.post(
        "/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        headers={"Authorization": f"Bearer {token['access_token']}", "Accept": "application/json, text/event-stream"},
    )
    assert response.status_code == 401


async def test_mcp_database_role_is_read_only_and_row_limited(app, client):
    stephen = await make_user(app, "stephen")
    dee = await make_user(app, "dee")
    await seed(app, client, "stephen", steps=10000, heart_rate=60)
    await seed(app, client, "dee", steps=5000, heart_rate=80)
    db = app.state.db

    async with db.read_as(stephen) as conn:
        user_ids = (await conn.execute(text("SELECT DISTINCT user_id FROM samples"))).scalars().all()
        visible_users = (await conn.execute(text("SELECT id FROM users"))).scalars().all()
    assert user_ids == [stephen]
    assert visible_users == [stephen]

    async with db.read_as(dee) as conn:
        assert (await conn.execute(text("SELECT count(*) FROM daily_summaries WHERE user_id = :id"), {"id": stephen})).scalar_one() == 0

    with pytest.raises(DBAPIError, match="read-only transaction"):
        async with db.read_as(stephen) as conn:
            await conn.execute(text("DELETE FROM samples"))
    with pytest.raises(DBAPIError, match="permission denied"):
        async with db.read_as(stephen) as conn:
            await conn.execute(text("SELECT token_hash FROM oauth_tokens"))
    with pytest.raises(DBAPIError, match="permission denied"):
        async with db.read_as(stephen) as conn:
            await conn.execute(text("SELECT password_hash FROM users"))
