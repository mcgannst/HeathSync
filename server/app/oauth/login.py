"""The page people see when they connect HealthSync to Claude."""

import html

from fastapi import APIRouter, Depends, Form, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response

from app.api.deps import get_db, get_throttle
from app.db import Database
from app.security import LoginThrottle
from app.users import LoginBlocked, authenticate

router = APIRouter(include_in_schema=False)

_HEADERS = {
    "Cache-Control": "no-store",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
    "Referrer-Policy": "no-referrer",
}

_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in · HealthSync</title>
<style>
:root { color-scheme: light dark; --bg: #f2f2f7; --card: #fff; --text: #1c1c1e; --muted: #636366;
        --border: #d1d1d6; --accent: #e0245e; --error: #c4001a; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #000; --card: #1c1c1e; --text: #f2f2f7; --muted: #98989f; --border: #38383a; --error: #ff6b81; }
}
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 16px;
       background: var(--bg); color: var(--text); font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
main { width: 100%; max-width: 380px; background: var(--card); border: 1px solid var(--border); border-radius: 16px; padding: 28px; }
h1 { font-size: 22px; margin: 0 0 6px; }
p { margin: 0 0 18px; color: var(--muted); }
label { display: block; font-size: 14px; font-weight: 600; margin: 14px 0 6px; }
input { width: 100%; padding: 11px 12px; border: 1px solid var(--border); border-radius: 10px;
        font: inherit; color: inherit; background: transparent; }
input:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
button { margin-top: 22px; width: 100%; padding: 12px; border: 0; border-radius: 10px;
         background: var(--accent); color: #fff; font: inherit; font-weight: 600; cursor: pointer; }
.error { color: var(--error); font-weight: 600; }
</style>
</head>
<body><main>{body}</main></body>
</html>"""


def _page(body: str, status_code: int = 200) -> HTMLResponse:
    return HTMLResponse(_PAGE.replace("{body}", body), status_code=status_code, headers=_HEADERS)


def _form(request_id: str, client_name: str | None, error: str | None = None, username: str = "") -> str:
    who = html.escape(client_name or "An app")
    message = f'<p class="error" role="alert">{html.escape(error)}</p>' if error else ""
    return f"""
<h1>Sign in to HealthSync</h1>
<p>{who} is asking for read-only access to your health data.</p>
{message}
<form method="post" action="/oauth/login">
  <input type="hidden" name="request" value="{html.escape(request_id)}">
  <label for="username">Username</label>
  <input id="username" name="username" value="{html.escape(username)}" autocomplete="username"
         autocapitalize="none" autocorrect="off" required autofocus>
  <label for="password">Password</label>
  <input id="password" name="password" type="password" autocomplete="current-password" required>
  <button type="submit">Allow read-only access</button>
</form>"""


_EXPIRED = """
<h1>This link has expired</h1>
<p>Go back to Claude and connect HealthSync again.</p>"""


@router.get("/oauth/login")
async def login_page(request: Request, request_id: str = Query(alias="request")) -> Response:
    pending = await request.app.state.oauth_provider.pending_authorization(request_id)
    if pending is None:
        return _page(_EXPIRED, status_code=400)
    return _page(_form(request_id, pending.client_name))


@router.post("/oauth/login")
async def submit_login(
    request: Request,
    request_id: str = Form(alias="request"),
    username: str = Form(max_length=100),
    password: str = Form(max_length=200),
    db: Database = Depends(get_db),
    throttle: LoginThrottle = Depends(get_throttle),
) -> Response:
    provider = request.app.state.oauth_provider
    pending = await provider.pending_authorization(request_id)
    if pending is None:
        return _page(_EXPIRED, status_code=400)

    async with db.write() as conn:
        try:
            user = await authenticate(conn, throttle, username, password)
        except LoginBlocked:
            return _page(
                _form(request_id, pending.client_name, "Too many failed attempts. Try again in 15 minutes.", username),
                status_code=429,
            )
    if user is None:
        return _page(_form(request_id, pending.client_name, "Incorrect username or password.", username), status_code=401)

    redirect_url = await provider.complete_authorization(request_id, user["id"])
    if redirect_url is None:
        return _page(_EXPIRED, status_code=400)
    return RedirectResponse(redirect_url, status_code=302, headers={"Cache-Control": "no-store"})
