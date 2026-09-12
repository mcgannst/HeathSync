import pytest
from sqlalchemy import text

from tests.helpers import PASSWORD, login, make_user, sample, summary

pytestmark = pytest.mark.anyio


async def test_login_is_case_insensitive_and_returns_the_user(app, client):
    await make_user(app, "stephen", is_admin=True)
    headers = await login(client, "Stephen")

    me = await client.get("/api/v1/me", headers=headers)
    assert me.status_code == 200
    assert me.json()["username"] == "stephen"
    assert me.json()["is_admin"] is True
    # Local time with its offset (Edmonton is UTC-6 in September).
    assert me.json()["created_at"].endswith("-06:00")


async def test_repeated_wrong_passwords_block_the_username(app, client):
    await make_user(app, "dee")
    attempt = {"username": "dee", "password": "wrong-password", "device_name": "iPhone"}
    for _ in range(5):
        assert (await client.post("/api/v1/auth/login", json=attempt)).status_code == 401

    blocked = await client.post("/api/v1/auth/login", json={**attempt, "password": PASSWORD})
    assert blocked.status_code == 429


async def test_requests_need_a_valid_token(client):
    assert (await client.get("/api/v1/me")).status_code == 401
    assert (await client.post("/api/v1/sync/samples", json={})).status_code == 401
    bogus = {"Authorization": "Bearer not-a-real-token"}
    assert (await client.get("/api/v1/me", headers=bogus)).status_code == 401


async def test_logout_revokes_the_token(app, client):
    await make_user(app, "stephen")
    headers = await login(client, "stephen")

    assert (await client.post("/api/v1/auth/logout", headers=headers)).status_code == 204
    assert (await client.get("/api/v1/me", headers=headers)).status_code == 401


async def test_sample_uploads_are_idempotent_and_apply_deletions(app, client):
    await make_user(app, "stephen")
    headers = await login(client, "stephen")
    batch = [
        sample(),
        sample(value=71),
        sample(type="sleepAnalysis", value=None, unit=None, category="asleepDeep", end="2026-09-01T09:00:00-06:00"),
    ]

    first = await client.post("/api/v1/sync/samples", json={"samples": batch}, headers=headers)
    assert first.json() == {"received": 3, "inserted": 3, "deleted": 0}
    again = await client.post("/api/v1/sync/samples", json={"samples": batch}, headers=headers)
    assert again.json() == {"received": 3, "inserted": 0, "deleted": 0}
    removed = await client.post("/api/v1/sync/samples", json={"deleted": [batch[0]["uuid"]]}, headers=headers)
    assert removed.json()["deleted"] == 1

    status = (await client.get("/api/v1/sync/status", headers=headers)).json()
    assert {row["type"]: row["count"] for row in status["samples"]} == {"heartRate": 1, "sleepAnalysis": 1}
    assert status["samples"][0]["first"] == "2026-09-01T08:00:00-06:00"
    assert status["last_sync_at"] is not None


async def test_invalid_samples_are_rejected(app, client):
    await make_user(app, "stephen")
    headers = await login(client, "stephen")

    no_value = await client.post("/api/v1/sync/samples", json={"samples": [sample(value=None)]}, headers=headers)
    assert no_value.status_code == 422
    no_offset = await client.post(
        "/api/v1/sync/samples", json={"samples": [sample(start="2026-09-01T08:00:00")]}, headers=headers
    )
    assert no_offset.status_code == 422


async def test_the_same_healthkit_sample_can_belong_to_two_people(app, client):
    await make_user(app, "stephen")
    await make_user(app, "dee")
    shared = sample()

    for username in ("stephen", "dee"):
        headers = await login(client, username)
        response = await client.post("/api/v1/sync/samples", json={"samples": [shared]}, headers=headers)
        assert response.json()["inserted"] == 1


async def test_daily_summaries_upsert_and_update_the_time_zone(app, client):
    user_id = await make_user(app, "stephen")
    headers = await login(client, "stephen")

    first = await client.post(
        "/api/v1/sync/daily",
        json={
            "time_zone": "America/Vancouver",
            "summaries": [
                summary("2026-09-01", "stepCount", "sum", 8000, "count"),
                summary("2026-09-01", "stepCount", "sum", 9000, "count"),
            ],
        },
        headers=headers,
    )
    assert first.json() == {"received": 2, "inserted": 1, "deleted": 0}
    await client.post(
        "/api/v1/sync/daily",
        json={"summaries": [summary("2026-09-01", "stepCount", "sum", 9500, "count")]},
        headers=headers,
    )

    async with app.state.db.write() as conn:
        value = (
            await conn.execute(text("SELECT value FROM daily_summaries WHERE user_id = :id"), {"id": user_id})
        ).scalar_one()
    assert value == 9500
    assert (await client.get("/api/v1/me", headers=headers)).json()["time_zone"] == "America/Vancouver"

    bad_zone = await client.post("/api/v1/sync/daily", json={"time_zone": "Mars/Olympus"}, headers=headers)
    assert bad_zone.status_code == 422


async def test_workout_upload(app, client):
    await make_user(app, "stephen")
    headers = await login(client, "stephen")
    workout = {
        "uuid": "6f0c8a4e-0d3e-4c55-9c57-2f1f3f0e8a11",
        "activity_type": "running",
        "start": "2026-09-01T07:00:00-06:00",
        "end": "2026-09-01T07:45:00-06:00",
        "duration_s": 2700,
        "active_energy_kcal": 480,
        "distance_m": 7400,
    }

    response = await client.post("/api/v1/sync/workouts", json={"workouts": [workout]}, headers=headers)
    assert response.json() == {"received": 1, "inserted": 1, "deleted": 0}
    assert (await client.get("/api/v1/sync/status", headers=headers)).json()["workout_count"] == 1


async def test_admin_creates_and_disables_accounts(app, client):
    admin_id = await make_user(app, "stephen", is_admin=True)
    admin = await login(client, "stephen")

    created = await client.post(
        "/api/v1/admin/users",
        json={"username": "dee", "display_name": "Dee", "password": "another-long-password"},
        headers=admin,
    )
    assert created.status_code == 201
    dee_id = created.json()["id"]
    duplicate = await client.post(
        "/api/v1/admin/users",
        json={"username": "DEE", "display_name": "Dee", "password": "another-long-password"},
        headers=admin,
    )
    assert duplicate.status_code == 409

    dee = await login(client, "dee", "another-long-password")
    assert (await client.get("/api/v1/admin/users", headers=dee)).status_code == 403

    disabled = await client.patch(f"/api/v1/admin/users/{dee_id}", json={"is_active": False}, headers=admin)
    assert disabled.status_code == 200
    assert disabled.json()["is_active"] is False
    assert (await client.get("/api/v1/me", headers=dee)).status_code == 401
    retry = {"username": "dee", "password": "another-long-password", "device_name": "iPhone"}
    assert (await client.post("/api/v1/auth/login", json=retry)).status_code == 401

    own = await client.patch(f"/api/v1/admin/users/{admin_id}", json={"is_active": False}, headers=admin)
    assert own.status_code == 400
    listing = await client.get("/api/v1/admin/users", headers=admin)
    assert [user["username"] for user in listing.json()] == ["dee", "stephen"]


async def test_password_reset_signs_the_person_out(app, client):
    await make_user(app, "stephen", is_admin=True)
    twyla_id = await make_user(app, "twyla")
    admin = await login(client, "stephen")
    twyla = await login(client, "twyla")

    reset = await client.patch(
        f"/api/v1/admin/users/{twyla_id}", json={"password": "a-brand-new-password"}, headers=admin
    )
    assert reset.status_code == 200
    assert (await client.get("/api/v1/me", headers=twyla)).status_code == 401
    await login(client, "twyla", "a-brand-new-password")
    assert (await client.get("/api/v1/me", headers=admin)).status_code == 200
