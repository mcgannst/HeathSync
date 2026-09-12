"""Read-only MCP tools over one person's Health data.

Every tool resolves the signed-in user from the OAuth token and queries through `Database.read_as`, which
uses a SELECT-only Postgres role with row security. The WHERE clauses below therefore never filter by
user: the database already limits every table to that person's rows.
"""

from datetime import date, datetime, time, timedelta
from typing import Any, Literal
from zoneinfo import ZoneInfo

from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions, RevocationOptions
from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from app.config import Settings
from app.db import Database
from app.oauth.provider import SCOPE, HealthSyncOAuthProvider

MAX_RANGE_DAYS = 1100
MAX_SAMPLE_ROWS = 5000
TIME_STATS = ("bedtime", "wake_time")

INSTRUCTIONS = """\
HealthSync gives read-only access to one person's Apple Health data, uploaded from their iPhone.

- Call get_overview first: it lists which metrics exist, their units, and the dates they cover.
- Metric names are HealthKit identifiers without the prefix, e.g. stepCount, activeEnergyBurned, \
appleExerciseTime, heartRate, restingHeartRate, heartRateVariabilitySDNN, oxygenSaturation, respiratoryRate, \
bodyMass, bodyFatPercentage, bloodPressureSystolic, bloodGlucose, vo2Max, sleepAnalysis, mindfulSession, \
menstrualFlow.
- For totals, averages and trends use get_daily_summaries or compare_periods. Daily summaries are \
de-duplicated across iPhone and Apple Watch; raw samples overlap, so never add samples up for a total.
- All dates and times are in the person's own time zone (see get_overview). Date ranges are inclusive.
- Units: energy kcal, distance m, exercise/stand/mindful time min, sleep hours, heart rate and respiratory rate \
count/min, HRV ms, percentages 0-100, weight kg, temperature degC, blood pressure mmHg, glucose mg/dL, \
VO2 max mL/kg/min, audio exposure dBASPL.
- This is personal data from consumer devices, not a medical record.
"""

READ_ONLY = ToolAnnotations(read_only_hint=True, destructive_hint=False, idempotent_hint=True, open_world_hint=False)


def build_mcp(db: Database, settings: Settings, provider: HealthSyncOAuthProvider) -> MCPServer:
    mcp = MCPServer(
        name="healthsync",
        title="HealthSync",
        instructions=INSTRUCTIONS,
        version="1.0.0",
        auth_server_provider=provider,
        auth=AuthSettings(
            issuer_url=settings.issuer_url,
            resource_server_url=settings.mcp_url,
            validate_token_resource=True,
            required_scopes=[SCOPE],
            client_registration_options=ClientRegistrationOptions(
                enabled=True, valid_scopes=[SCOPE], default_scopes=[SCOPE]
            ),
            revocation_options=RevocationOptions(enabled=True),
        ),
    )

    @mcp.tool(annotations=READ_ONLY)
    async def get_overview() -> dict[str, Any]:
        """Start here. Whose data this is, their time zone, when their iPhone last synced, and every
        available metric with its unit, date coverage and daily stats, plus workout types."""
        async with db.read_as(_user_id()) as conn:
            user = (
                await conn.execute(text("SELECT display_name, time_zone, last_sync_at FROM users"))
            ).mappings().one_or_none()
            if user is None:
                raise ToolError("HealthSync account not found.")
            zone = ZoneInfo(user["time_zone"])
            daily = (
                await conn.execute(
                    text(
                        """
                        SELECT metric, array_agg(DISTINCT stat ORDER BY stat) AS stats, min(unit) AS unit,
                               min(day) AS first_day, max(day) AS last_day, count(DISTINCT day) AS days
                        FROM daily_summaries GROUP BY metric ORDER BY metric
                        """
                    )
                )
            ).mappings().all()
            samples = (
                await conn.execute(
                    text(
                        """
                        SELECT type, min(unit) AS unit, count(*) AS count, min(start_at) AS first, max(end_at) AS last
                        FROM samples GROUP BY type ORDER BY type
                        """
                    )
                )
            ).mappings().all()
            workouts = (
                await conn.execute(
                    text(
                        """
                        SELECT activity_type, count(*) AS count, min(start_at) AS first, max(start_at) AS last
                        FROM workouts GROUP BY activity_type ORDER BY count(*) DESC
                        """
                    )
                )
            ).mappings().all()

        return {
            "name": user["display_name"],
            "time_zone": user["time_zone"],
            "last_sync": _local(user["last_sync_at"], zone),
            "daily_summaries": [
                {
                    "metric": row["metric"],
                    "stats": list(row["stats"]),
                    "unit": row["unit"],
                    "first_day": row["first_day"].isoformat(),
                    "last_day": row["last_day"].isoformat(),
                    "days_with_data": row["days"],
                }
                for row in daily
            ],
            "samples": [
                {
                    "type": row["type"],
                    "unit": row["unit"],
                    "count": row["count"],
                    "first": _local(row["first"], zone),
                    "last": _local(row["last"], zone),
                }
                for row in samples
            ],
            "workouts": [
                {
                    "activity_type": row["activity_type"],
                    "count": row["count"],
                    "first": _local(row["first"], zone),
                    "last": _local(row["last"], zone),
                }
                for row in workouts
            ],
        }

    @mcp.tool(annotations=READ_ONLY)
    async def get_daily_summaries(
        start_date: date,
        end_date: date,
        metrics: list[str] | None = None,
        stats: list[str] | None = None,
    ) -> dict[str, Any]:
        """Daily statistics per metric: step totals, average/min/max heart rate, sleep stages, weight and so on.
        De-duplicated across iPhone and Apple Watch, so use this (not raw samples) for totals and trends.
        Dates are inclusive. Optionally filter by metrics (e.g. ["stepCount", "restingHeartRate"]) and stats
        (sum, avg, min, max, latest; sleep uses asleep, core, deep, rem, awake, in_bed, bedtime, wake_time).
        Each returned day has keys like "stepCount.sum"; units are listed once under "units"."""
        _check_dates(start_date, end_date)
        async with db.read_as(_user_id()) as conn:
            zone = await _zone(conn)
            query = "SELECT day, metric, stat, value, unit FROM daily_summaries WHERE day BETWEEN :start AND :end"
            params: dict[str, Any] = {"start": start_date, "end": end_date}
            if metrics:
                query += " AND metric = ANY(:metrics)"
                params["metrics"] = metrics
            if stats:
                query += " AND stat = ANY(:stats)"
                params["stats"] = stats
            rows = (await conn.execute(text(query + " ORDER BY day, metric, stat"), params)).mappings().all()

        units: dict[str, str] = {}
        days: dict[str, dict[str, Any]] = {}
        for row in rows:
            key = f"{row['metric']}.{row['stat']}"
            units[key] = "local time" if row["stat"] in TIME_STATS else row["unit"]
            days.setdefault(row["day"].isoformat(), {})[key] = _stat_value(row["stat"], row["value"], zone)
        return {
            "time_zone": str(zone),
            "units": units,
            "days": [{"date": day, **values} for day, values in days.items()],
        }

    @mcp.tool(annotations=READ_ONLY)
    async def get_samples(
        metric: str,
        start: str,
        end: str,
        bucket: Literal["none", "hour", "day"] = "none",
        limit: int = 500,
    ) -> dict[str, Any]:
        """Individual readings for one metric between two moments, e.g. heart rate during a run or glucose
        after a meal. start and end accept YYYY-MM-DD (whole days, inclusive) or ISO 8601 date-times; times
        without an offset are in the person's time zone. With bucket="hour" or "day" you get count, avg, min,
        max and sum per bucket instead of individual readings. Category metrics (sleepAnalysis, mindfulSession,
        menstrualFlow...) return a category and duration. Results are capped at limit (max 5000)."""
        limit = max(1, min(limit, MAX_SAMPLE_ROWS))
        async with db.read_as(_user_id()) as conn:
            zone = await _zone(conn)
            start_at = _moment(start, zone, is_end=False)
            end_at = _moment(end, zone, is_end=True)
            if end_at <= start_at:
                raise ToolError("end must be after start.")
            if end_at - start_at > timedelta(days=MAX_RANGE_DAYS):
                raise ToolError(f"Time ranges are limited to {MAX_RANGE_DAYS} days.")
            params: dict[str, Any] = {"metric": metric, "start": start_at, "end": end_at, "limit": limit}
            where = "type = :metric AND start_at >= :start AND start_at < :end"

            if bucket == "none":
                total = (await conn.execute(text(f"SELECT count(*) FROM samples WHERE {where}"), params)).scalar_one()
                rows = (
                    await conn.execute(
                        text(
                            f"""
                            SELECT start_at, end_at, value, unit, category, source_name
                            FROM samples WHERE {where} ORDER BY start_at LIMIT :limit
                            """
                        ),
                        params,
                    )
                ).mappings().all()
                return {
                    "metric": metric,
                    "time_zone": str(zone),
                    "total": total,
                    "returned": len(rows),
                    "truncated": total > len(rows),
                    "samples": [
                        _drop_none(
                            {
                                "start": _local(row["start_at"], zone),
                                "end": _local(row["end_at"], zone) if row["end_at"] != row["start_at"] else None,
                                "value": _round(row["value"], 3),
                                "unit": row["unit"],
                                "category": row["category"],
                                "source": row["source_name"],
                            }
                        )
                        for row in rows
                    ],
                }

            params["bucket"] = bucket
            params["zone"] = str(zone)
            rows = (
                await conn.execute(
                    text(
                        f"""
                        SELECT date_trunc(:bucket, start_at AT TIME ZONE :zone) AS bucket, unit, category,
                               count(*) AS count, avg(value) AS avg, min(value) AS min, max(value) AS max,
                               sum(value) AS sum, sum(extract(epoch FROM end_at - start_at)) / 60 AS minutes
                        FROM samples WHERE {where}
                        GROUP BY 1, unit, category ORDER BY 1, category LIMIT :limit
                        """
                    ),
                    params,
                )
            ).mappings().all()
        return {
            "metric": metric,
            "time_zone": str(zone),
            "bucket": bucket,
            "buckets": [
                _drop_none(
                    {
                        "start": row["bucket"].replace(tzinfo=zone).isoformat(timespec="minutes"),
                        "category": row["category"],
                        "count": row["count"],
                        "avg": _round(row["avg"], 2),
                        "min": _round(row["min"], 2),
                        "max": _round(row["max"], 2),
                        "sum": _round(row["sum"], 2),
                        "minutes": _round(row["minutes"], 1) if row["category"] else None,
                        "unit": row["unit"],
                    }
                )
                for row in rows
            ],
        }

    @mcp.tool(annotations=READ_ONLY)
    async def get_sleep(start_date: date, end_date: date) -> dict[str, Any]:
        """Night-by-night sleep: hours asleep, hours in core, deep and REM sleep, awake time, time in bed,
        bedtime and wake time. Each night is dated by the morning the person woke up. Dates are inclusive."""
        _check_dates(start_date, end_date)
        async with db.read_as(_user_id()) as conn:
            zone = await _zone(conn)
            rows = (
                await conn.execute(
                    text(
                        """
                        SELECT day, stat, value FROM daily_summaries
                        WHERE metric = 'sleepAnalysis' AND day BETWEEN :start AND :end ORDER BY day, stat
                        """
                    ),
                    {"start": start_date, "end": end_date},
                )
            ).mappings().all()

        nights: dict[str, dict[str, Any]] = {}
        for row in rows:
            key = row["stat"] if row["stat"] in TIME_STATS else f"{row['stat']}_hours"
            nights.setdefault(row["day"].isoformat(), {})[key] = _stat_value(row["stat"], row["value"], zone)
        return {"time_zone": str(zone), "nights": [{"date": day, **values} for day, values in nights.items()]}

    @mcp.tool(annotations=READ_ONLY)
    async def get_workouts(start_date: date, end_date: date, activity_type: str | None = None) -> dict[str, Any]:
        """Workouts between two dates (inclusive), with duration, active energy, distance, and average and
        maximum heart rate during the workout. activity_type filters by HealthKit type, e.g. running, walking,
        cycling, traditionalStrengthTraining (see get_overview for the types present)."""
        _check_dates(start_date, end_date)
        async with db.read_as(_user_id()) as conn:
            zone = await _zone(conn)
            start_at, end_at = _day_bounds(start_date, end_date, zone)
            query = """
                SELECT w.activity_type, w.start_at, w.end_at, w.duration_s, w.active_energy_kcal, w.distance_m,
                       w.source_name, hr.avg_hr, hr.max_hr
                FROM workouts w
                LEFT JOIN LATERAL (
                    SELECT avg(s.value) AS avg_hr, max(s.value) AS max_hr FROM samples s
                    WHERE s.type = 'heartRate' AND s.start_at >= w.start_at AND s.start_at <= w.end_at
                ) hr ON true
                WHERE w.start_at >= :start AND w.start_at < :end
            """
            params: dict[str, Any] = {"start": start_at, "end": end_at}
            if activity_type:
                query += " AND lower(w.activity_type) = lower(:activity_type)"
                params["activity_type"] = activity_type
            rows = (await conn.execute(text(query + " ORDER BY w.start_at LIMIT 1000"), params)).mappings().all()

        return {
            "time_zone": str(zone),
            "workouts": [
                _drop_none(
                    {
                        "activity_type": row["activity_type"],
                        "start": _local(row["start_at"], zone),
                        "end": _local(row["end_at"], zone),
                        "duration_minutes": _round(row["duration_s"] / 60, 1),
                        "active_energy_kcal": _round(row["active_energy_kcal"], 0),
                        "distance_km": _round(row["distance_m"] / 1000, 2) if row["distance_m"] is not None else None,
                        "avg_heart_rate": _round(row["avg_hr"], 0),
                        "max_heart_rate": _round(row["max_hr"], 0),
                        "source": row["source_name"],
                    }
                )
                for row in rows
            ],
        }

    @mcp.tool(annotations=READ_ONLY)
    async def compare_periods(
        metrics: list[str],
        period_a_start: date,
        period_a_end: date,
        period_b_start: date,
        period_b_end: date,
    ) -> dict[str, Any]:
        """Compares two date ranges, e.g. last month (A) with this month (B). For each metric and daily stat,
        returns the average daily value in each period, how many days had data, and the change from A to B.
        Dates are inclusive."""
        _check_dates(period_a_start, period_a_end)
        _check_dates(period_b_start, period_b_end)
        if not metrics:
            raise ToolError("Name at least one metric.")
        async with db.read_as(_user_id()) as conn:
            rows = (
                await conn.execute(
                    text(
                        """
                        SELECT metric, stat, min(unit) AS unit,
                               avg(value) FILTER (WHERE day BETWEEN :a_start AND :a_end) AS a_avg,
                               count(*) FILTER (WHERE day BETWEEN :a_start AND :a_end) AS a_days,
                               avg(value) FILTER (WHERE day BETWEEN :b_start AND :b_end) AS b_avg,
                               count(*) FILTER (WHERE day BETWEEN :b_start AND :b_end) AS b_days
                        FROM daily_summaries
                        WHERE metric = ANY(:metrics) AND stat <> ALL(:time_stats)
                          AND (day BETWEEN :a_start AND :a_end OR day BETWEEN :b_start AND :b_end)
                        GROUP BY metric, stat ORDER BY metric, stat
                        """
                    ),
                    {
                        "metrics": metrics,
                        "time_stats": list(TIME_STATS),
                        "a_start": period_a_start,
                        "a_end": period_a_end,
                        "b_start": period_b_start,
                        "b_end": period_b_end,
                    },
                )
            ).mappings().all()

        comparisons = []
        for row in rows:
            a, b = row["a_avg"], row["b_avg"]
            change = b - a if a is not None and b is not None else None
            comparisons.append(
                _drop_none(
                    {
                        "metric": row["metric"],
                        "stat": row["stat"],
                        "unit": row["unit"],
                        "period_a_daily_avg": _round(a, 2),
                        "period_a_days": row["a_days"],
                        "period_b_daily_avg": _round(b, 2),
                        "period_b_days": row["b_days"],
                        "change": _round(change, 2),
                        "percent_change": _round(change / a * 100, 1) if change is not None and a else None,
                    }
                )
            )
        return {
            "period_a": {"start": period_a_start.isoformat(), "end": period_a_end.isoformat()},
            "period_b": {"start": period_b_start.isoformat(), "end": period_b_end.isoformat()},
            "comparisons": comparisons,
        }

    return mcp


def _user_id() -> int:
    token = get_access_token()
    if token is None or token.subject is None:
        raise ToolError("Not signed in to HealthSync.")
    return int(token.subject)


async def _zone(conn: AsyncConnection) -> ZoneInfo:
    name = (await conn.execute(text("SELECT time_zone FROM users"))).scalar_one_or_none()
    if name is None:
        raise ToolError("HealthSync account not found.")
    return ZoneInfo(name)


def _check_dates(start: date, end: date) -> None:
    if end < start:
        raise ToolError("The end date is before the start date.")
    if (end - start).days > MAX_RANGE_DAYS:
        raise ToolError(f"Date ranges are limited to {MAX_RANGE_DAYS} days.")


def _day_bounds(start: date, end: date, zone: ZoneInfo) -> tuple[datetime, datetime]:
    return datetime.combine(start, time.min, zone), datetime.combine(end + timedelta(days=1), time.min, zone)


def _moment(value: str, zone: ZoneInfo, *, is_end: bool) -> datetime:
    """A bare date is the start of that day, or for an end bound the start of the next day (inclusive)."""
    value = value.strip()
    try:
        if len(value) == 10:
            day = date.fromisoformat(value)
            return datetime.combine(day + timedelta(days=1) if is_end else day, time.min, zone)
        moment = datetime.fromisoformat(value)
    except ValueError:
        raise ToolError(f"Couldn't read {value!r} as a date or time. Use YYYY-MM-DD or ISO 8601.") from None
    return moment if moment.tzinfo else moment.replace(tzinfo=zone)


def _stat_value(stat: str, value: float, zone: ZoneInfo) -> Any:
    if stat in TIME_STATS:
        return datetime.fromtimestamp(value, zone).isoformat(timespec="minutes")
    return _round(value, 2)


def _local(moment: datetime | None, zone: ZoneInfo) -> str | None:
    return moment.astimezone(zone).isoformat(timespec="seconds") if moment else None


def _round(value: float | None, digits: int) -> float | None:
    if value is None:
        return None
    rounded = round(float(value), digits)
    return int(rounded) if digits == 0 else rounded


def _drop_none(values: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in values.items() if value is not None}
