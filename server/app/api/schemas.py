from datetime import date, datetime
from typing import Any, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

# Daily statistics the iOS app computes. Sleep uses its own stats (hours per stage, plus bedtime and
# wake time as Unix seconds), everything else uses sum/avg/min/max/latest.
Stat = Literal[
    "sum", "avg", "min", "max", "latest",
    "asleep", "core", "deep", "rem", "awake", "in_bed", "unspecified", "bedtime", "wake_time",
]

MAX_SAMPLES_PER_UPLOAD = 5000
MAX_WORKOUTS_PER_UPLOAD = 1000
MAX_SUMMARIES_PER_UPLOAD = 10000

Name = Field(min_length=1, max_length=100)


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    username: str
    display_name: str
    is_admin: bool
    is_active: bool
    time_zone: str
    last_sync_at: datetime | None
    created_at: datetime

    @model_validator(mode="after")
    def _local_times(self) -> "UserOut":
        zone = ZoneInfo(self.time_zone)
        self.created_at = self.created_at.astimezone(zone)
        self.last_sync_at = self.last_sync_at.astimezone(zone) if self.last_sync_at else None
        return self


class LoginRequest(BaseModel):
    username: str = Name
    password: str = Field(min_length=1, max_length=200)
    device_name: str = Name


class LoginResponse(BaseModel):
    token: str
    user: UserOut


class SampleIn(BaseModel):
    uuid: UUID
    type: str = Name
    start: AwareDatetime
    end: AwareDatetime
    value: float | None = None
    unit: str | None = Field(default=None, max_length=50)
    category: str | None = Field(default=None, max_length=100)
    source_name: str | None = Field(default=None, max_length=200)
    source_bundle: str | None = Field(default=None, max_length=200)
    device: str | None = Field(default=None, max_length=200)
    metadata: dict[str, Any] | None = None

    @model_validator(mode="after")
    def _check(self) -> "SampleIn":
        if self.value is None and self.category is None:
            raise ValueError("a sample needs a value or a category")
        if self.end < self.start:
            raise ValueError("end is before start")
        return self


class SamplesUpload(BaseModel):
    samples: list[SampleIn] = Field(default_factory=list, max_length=MAX_SAMPLES_PER_UPLOAD)
    deleted: list[UUID] = Field(default_factory=list, max_length=MAX_SAMPLES_PER_UPLOAD)


class WorkoutIn(BaseModel):
    uuid: UUID
    activity_type: str = Name
    start: AwareDatetime
    end: AwareDatetime
    duration_s: float = Field(ge=0)
    active_energy_kcal: float | None = Field(default=None, ge=0)
    distance_m: float | None = Field(default=None, ge=0)
    source_name: str | None = Field(default=None, max_length=200)
    device: str | None = Field(default=None, max_length=200)
    metadata: dict[str, Any] | None = None


class WorkoutsUpload(BaseModel):
    workouts: list[WorkoutIn] = Field(default_factory=list, max_length=MAX_WORKOUTS_PER_UPLOAD)
    deleted: list[UUID] = Field(default_factory=list, max_length=MAX_WORKOUTS_PER_UPLOAD)


class DailySummaryIn(BaseModel):
    day: date
    metric: str = Name
    stat: Stat
    value: float
    unit: str = Field(min_length=1, max_length=50)


class DailyUpload(BaseModel):
    time_zone: str | None = None
    summaries: list[DailySummaryIn] = Field(default_factory=list, max_length=MAX_SUMMARIES_PER_UPLOAD)

    @field_validator("time_zone")
    @classmethod
    def _valid_zone(cls, value: str | None) -> str | None:
        if value is not None:
            try:
                ZoneInfo(value)
            except (ZoneInfoNotFoundError, ValueError) as error:
                raise ValueError(f"unknown time zone {value!r}") from error
        return value


class UploadResult(BaseModel):
    received: int
    inserted: int
    deleted: int


class TypeCoverage(BaseModel):
    type: str
    count: int
    first: datetime
    last: datetime


class SyncStatus(BaseModel):
    last_sync_at: datetime | None
    samples: list[TypeCoverage]
    workout_count: int
    daily_summary_count: int


class CreateUser(BaseModel):
    username: str = Field(pattern=r"^[A-Za-z0-9._-]{2,50}$")
    display_name: str = Name
    password: str = Field(min_length=10, max_length=200)
    is_admin: bool = False


class UpdateUser(BaseModel):
    display_name: str | None = Field(default=None, min_length=1, max_length=100)
    password: str | None = Field(default=None, min_length=10, max_length=200)
    is_active: bool | None = None
    is_admin: bool | None = None
