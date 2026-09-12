-- Accounts, iOS app sessions, OAuth for the MCP connector, and Health data.
-- Applied once by scripts/db.sh as the owner role; grants and row security live in db/grants.sql.

CREATE TABLE users (
    id             SERIAL PRIMARY KEY,
    username       TEXT NOT NULL,
    display_name   TEXT NOT NULL,
    password_hash  TEXT NOT NULL,
    is_admin       BOOLEAN NOT NULL DEFAULT FALSE,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    -- IANA zone the iOS app reports; defines "a day" for daily summaries and MCP date ranges.
    time_zone      TEXT NOT NULL DEFAULT 'America/Edmonton',
    last_sync_at   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_username_key ON users (lower(username));

-- Bearer tokens for the iOS app. Only a SHA-256 hash of each token is stored.
CREATE TABLE app_sessions (
    id            SERIAL PRIMARY KEY,
    user_id       INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash    TEXT NOT NULL UNIQUE,
    device_name   TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at    TIMESTAMPTZ
);
CREATE INDEX app_sessions_user_idx ON app_sessions (user_id);

-- OAuth clients registered dynamically (claude.ai registers itself).
CREATE TABLE oauth_clients (
    client_id    TEXT PRIMARY KEY,
    client_info  JSONB NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- An /authorize request waiting for the person to sign in on the login page.
CREATE TABLE oauth_pending_authorizations (
    id          TEXT PRIMARY KEY,
    client_id   TEXT NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
    params      JSONB NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL
);

CREATE TABLE oauth_codes (
    code_hash   TEXT PRIMARY KEY,
    client_id   TEXT NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
    user_id     INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    params      JSONB NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL
);

CREATE TABLE oauth_tokens (
    token_hash  TEXT PRIMARY KEY,
    kind        TEXT NOT NULL CHECK (kind IN ('access', 'refresh')),
    -- Shared by an access/refresh pair so revoking one revokes both.
    grant_id    UUID NOT NULL,
    client_id   TEXT NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
    user_id     INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    scopes      TEXT[] NOT NULL,
    resource    TEXT,
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at  TIMESTAMPTZ
);
CREATE INDEX oauth_tokens_grant_idx ON oauth_tokens (grant_id);
CREATE INDEX oauth_tokens_user_idx ON oauth_tokens (user_id);

-- One row per HealthKit quantity or category sample. HealthKit samples are immutable,
-- so uploads insert-or-ignore on the HealthKit UUID and deletions arrive as UUID lists.
CREATE TABLE samples (
    id             BIGSERIAL PRIMARY KEY,
    user_id        INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    hk_uuid        UUID NOT NULL,
    type           TEXT NOT NULL,
    start_at       TIMESTAMPTZ NOT NULL,
    end_at         TIMESTAMPTZ NOT NULL,
    value          DOUBLE PRECISION,
    unit           TEXT,
    -- Category samples (sleep stage, menstrual flow, ...) carry a label instead of a value.
    category       TEXT,
    source_name    TEXT,
    source_bundle  TEXT,
    device         TEXT,
    metadata       JSONB,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT samples_value_or_category CHECK (value IS NOT NULL OR category IS NOT NULL),
    CONSTRAINT samples_user_uuid_key UNIQUE (user_id, hk_uuid)
);
CREATE INDEX samples_user_type_start_idx ON samples (user_id, type, start_at);

CREATE TABLE workouts (
    id                  BIGSERIAL PRIMARY KEY,
    user_id             INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    hk_uuid             UUID NOT NULL,
    activity_type       TEXT NOT NULL,
    start_at            TIMESTAMPTZ NOT NULL,
    end_at              TIMESTAMPTZ NOT NULL,
    duration_s          DOUBLE PRECISION NOT NULL,
    active_energy_kcal  DOUBLE PRECISION,
    distance_m          DOUBLE PRECISION,
    source_name         TEXT,
    device              TEXT,
    metadata            JSONB,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT workouts_user_uuid_key UNIQUE (user_id, hk_uuid)
);
CREATE INDEX workouts_user_start_idx ON workouts (user_id, start_at);

-- Per-day statistics computed on the device with HealthKit's statistics queries,
-- which de-duplicate overlapping iPhone and Apple Watch samples. Summing raw samples would double count.
CREATE TABLE daily_summaries (
    user_id     INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    metric      TEXT NOT NULL,
    stat        TEXT NOT NULL,
    day         DATE NOT NULL,
    value       DOUBLE PRECISION NOT NULL,
    unit        TEXT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, metric, stat, day)
);
CREATE INDEX daily_summaries_user_day_idx ON daily_summaries (user_id, day);
