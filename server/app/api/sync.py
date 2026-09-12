import json
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends
from sqlalchemy import text

from app.api.deps import CurrentUser, current_user, get_db
from app.api.schemas import (
    DailyUpload,
    SamplesUpload,
    SyncStatus,
    TypeCoverage,
    UploadResult,
    WorkoutsUpload,
)
from app.db import Database

router = APIRouter(prefix="/api/v1/sync", tags=["sync"])

# Each upload is a single statement over a JSON array, so large batches make one round trip.
_INSERT_SAMPLES = text(
    """
    INSERT INTO samples (user_id, hk_uuid, type, start_at, end_at, value, unit, category,
                         source_name, source_bundle, device, metadata)
    SELECT :user_id, r.uuid, r.type, r.start, r."end", r.value, r.unit, r.category,
           r.source_name, r.source_bundle, r.device, r.metadata
    FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS r(
        uuid uuid, type text, start timestamptz, "end" timestamptz, value double precision, unit text,
        category text, source_name text, source_bundle text, device text, metadata jsonb)
    ON CONFLICT ON CONSTRAINT samples_user_uuid_key DO NOTHING
    """
)

_INSERT_WORKOUTS = text(
    """
    INSERT INTO workouts (user_id, hk_uuid, activity_type, start_at, end_at, duration_s,
                          active_energy_kcal, distance_m, source_name, device, metadata)
    SELECT :user_id, r.uuid, r.activity_type, r.start, r."end", r.duration_s,
           r.active_energy_kcal, r.distance_m, r.source_name, r.device, r.metadata
    FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS r(
        uuid uuid, activity_type text, start timestamptz, "end" timestamptz, duration_s double precision,
        active_energy_kcal double precision, distance_m double precision, source_name text, device text,
        metadata jsonb)
    ON CONFLICT ON CONSTRAINT workouts_user_uuid_key DO NOTHING
    """
)

_UPSERT_SUMMARIES = text(
    """
    INSERT INTO daily_summaries (user_id, metric, stat, day, value, unit, updated_at)
    SELECT :user_id, r.metric, r.stat, r.day, r.value, r.unit, now()
    FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS r(
        metric text, stat text, day date, value double precision, unit text)
    ON CONFLICT (user_id, metric, stat, day)
    DO UPDATE SET value = EXCLUDED.value, unit = EXCLUDED.unit, updated_at = now()
    """
)

_MARK_SYNCED = text("UPDATE users SET last_sync_at = now() WHERE id = :user_id")


@router.post("/samples", response_model=UploadResult)
async def upload_samples(
    body: SamplesUpload, user: CurrentUser = Depends(current_user), db: Database = Depends(get_db)
) -> UploadResult:
    inserted = deleted = 0
    async with db.write() as conn:
        if body.samples:
            rows = json.dumps([sample.model_dump(mode="json") for sample in body.samples])
            inserted = (await conn.execute(_INSERT_SAMPLES, {"user_id": user.id, "rows": rows})).rowcount
        if body.deleted:
            deleted = (
                await conn.execute(
                    text("DELETE FROM samples WHERE user_id = :user_id AND hk_uuid = ANY(CAST(:uuids AS uuid[]))"),
                    {"user_id": user.id, "uuids": [str(uuid) for uuid in body.deleted]},
                )
            ).rowcount
        await conn.execute(_MARK_SYNCED, {"user_id": user.id})
    return UploadResult(received=len(body.samples), inserted=inserted, deleted=deleted)


@router.post("/workouts", response_model=UploadResult)
async def upload_workouts(
    body: WorkoutsUpload, user: CurrentUser = Depends(current_user), db: Database = Depends(get_db)
) -> UploadResult:
    inserted = deleted = 0
    async with db.write() as conn:
        if body.workouts:
            rows = json.dumps([workout.model_dump(mode="json") for workout in body.workouts])
            inserted = (await conn.execute(_INSERT_WORKOUTS, {"user_id": user.id, "rows": rows})).rowcount
        if body.deleted:
            deleted = (
                await conn.execute(
                    text("DELETE FROM workouts WHERE user_id = :user_id AND hk_uuid = ANY(CAST(:uuids AS uuid[]))"),
                    {"user_id": user.id, "uuids": [str(uuid) for uuid in body.deleted]},
                )
            ).rowcount
        await conn.execute(_MARK_SYNCED, {"user_id": user.id})
    return UploadResult(received=len(body.workouts), inserted=inserted, deleted=deleted)


@router.post("/daily", response_model=UploadResult)
async def upload_daily(
    body: DailyUpload, user: CurrentUser = Depends(current_user), db: Database = Depends(get_db)
) -> UploadResult:
    # Postgres rejects an upsert that touches the same row twice, so keep the last value per key.
    latest = {(s.metric, s.stat, s.day): s for s in body.summaries}
    inserted = 0
    async with db.write() as conn:
        if body.time_zone:
            await conn.execute(
                text("UPDATE users SET time_zone = :zone, updated_at = now() WHERE id = :user_id AND time_zone <> :zone"),
                {"zone": body.time_zone, "user_id": user.id},
            )
        if latest:
            rows = json.dumps([summary.model_dump(mode="json") for summary in latest.values()])
            inserted = (await conn.execute(_UPSERT_SUMMARIES, {"user_id": user.id, "rows": rows})).rowcount
        await conn.execute(_MARK_SYNCED, {"user_id": user.id})
    return UploadResult(received=len(body.summaries), inserted=inserted, deleted=0)


@router.get("/status", response_model=SyncStatus)
async def sync_status(user: CurrentUser = Depends(current_user), db: Database = Depends(get_db)) -> SyncStatus:
    params = {"user_id": user.id}
    async with db.write() as conn:
        types = (
            await conn.execute(
                text(
                    """
                    SELECT type, count(*) AS count, min(start_at) AS first, max(end_at) AS last
                    FROM samples WHERE user_id = :user_id GROUP BY type ORDER BY type
                    """
                ),
                params,
            )
        ).mappings().all()
        workout_count = (
            await conn.execute(text("SELECT count(*) FROM workouts WHERE user_id = :user_id"), params)
        ).scalar_one()
        summary_count = (
            await conn.execute(text("SELECT count(*) FROM daily_summaries WHERE user_id = :user_id"), params)
        ).scalar_one()
        user = (
            await conn.execute(text("SELECT last_sync_at, time_zone FROM users WHERE id = :user_id"), params)
        ).mappings().one()
    zone = ZoneInfo(user["time_zone"])
    return SyncStatus(
        last_sync_at=user["last_sync_at"].astimezone(zone) if user["last_sync_at"] else None,
        samples=[
            TypeCoverage(
                type=row["type"], count=row["count"], first=row["first"].astimezone(zone), last=row["last"].astimezone(zone)
            )
            for row in types
        ],
        workout_count=workout_count,
        daily_summary_count=summary_count,
    )
