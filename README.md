# HealthSync

HealthSync uploads Apple Health data from each family member's iPhone to a private server, and gives Claude read-only access to it through an MCP connector.

```
iPhone app ──HTTPS──▶ HealthSync server ──▶ PostgreSQL (192.168.68.86)
                       │  (Docker on 192.168.68.73, behind a Cloudflare Tunnel)
claude.ai ──OAuth──▶  └─ /mcp  read-only tools
```

- Each person signs in to the app and to Claude with their own account. Claude only ever sees that person's data: the MCP tools query through a SELECT-only database role with row-level security.
- Accounts are created by an admin from the **Accounts** screen in the app. There is no public sign-up.
- Timestamps are stored as absolute instants and always shown in local time with their UTC offset.

## Repository

| Folder | What's there |
| --- | --- |
| `ios/` | SwiftUI app for iPhone and iPad (iOS 18+) |
| `server/` | FastAPI app: upload API, OAuth sign-in, MCP server |
| `db/` | SQL migrations and grants |
| `scripts/` | Database setup, Cloudflare Tunnel setup, deploy |
| `deploy/` | Compose files, plus gitignored env files with credentials |

## What gets uploaded

Groups can be turned on or off per person in the app. The first sync backfills the last two years; after that only new samples (and deletions) are sent.

| Group | HealthKit data |
| --- | --- |
| Activity | Steps, walking/running and cycling distance, active and resting energy, exercise and stand time, flights climbed |
| Heart | Heart rate, resting and walking heart rate, HRV, blood oxygen, respiratory rate |
| Sleep | Sleep stages, time asleep and in bed |
| Body | Weight, body fat, BMI, lean body mass |
| Vitals | Blood pressure, blood glucose, body and sleeping wrist temperature, VO2 max |
| Workouts | Type, duration, distance, active energy |
| Mindfulness & Cycle | Mindful sessions, menstrual flow, spotting, ovulation tests, environmental and headphone sound levels |

The server stores every raw sample plus daily statistics. Daily statistics are computed on the iPhone by HealthKit, which de-duplicates overlapping iPhone and Apple Watch data.

## MCP tools

All tools are read-only and answer in the person's local time zone.

| Tool | Use |
| --- | --- |
| `get_overview` | Who the data belongs to, last sync, available metrics and date coverage |
| `get_daily_summaries` | Daily totals/averages per metric over a date range |
| `get_samples` | Raw readings for one metric, or hourly/daily buckets |
| `get_sleep` | Night-by-night sleep stages, bedtime and wake time |
| `get_workouts` | Workouts with duration, distance, energy and heart rate |
| `compare_periods` | Average daily values in two date ranges, with the change |

To connect: in Claude, **Settings → Connectors → Add custom connector**, URL `https://healthsync.sunspinner.ca/mcp` (the app shows it under **Connect Claude**), then sign in with your HealthSync username and password.

## Environments

| | Test | Prod |
| --- | --- | --- |
| Public URL | https://healthsync-test.sunspinner.ca | https://healthsync.sunspinner.ca |
| LAN | http://192.168.68.73:3031 | http://192.168.68.73:3030 |
| Database | `healthsync_test` | `healthsync_prod` |

Each database has three roles: `<db>_owner` (owns the schema), `<db>_app` (API, read-write) and `<db>_mcp` (MCP tools, read-only with row security).

## Setting up an environment

Credentials live in gitignored files in `deploy/`:

- `deploy/.env.pgadmin`: a Postgres superuser URL (see `pgadmin.env.example`)
- `deploy/.env.cloudflare`: an API token with Cloudflare Tunnel and DNS edit rights (see `cloudflare.env.example`)

Then, for `test` (or `prod`):

```sh
bash scripts/db.sh test               # roles, database, migrations, grants; writes deploy/.env.test
bash scripts/cf-tunnel-setup.sh test  # tunnel + DNS; writes deploy/.env.test.tunnel
bash scripts/deploy.sh test           # build, ship, start, health check
docker --context shared-docker-server exec -it healthsync-test python -m app.cli create-user stephen --name Stephen --admin
```

Backups are handled by Proxmox, outside this repo.

All scripts are safe to re-run. Add a schema change as a new file in `db/migrations/` and run `scripts/db.sh` again.

## Development

Server tests run against a local Postgres 14 with the same roles and row security as the real environments:

```sh
docker run -d --name healthsync-pg-local -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:14
PGADMIN_URL=postgresql://postgres:postgres@localhost:55432/postgres bash scripts/db.sh local
cd server && python -m venv .venv && .venv/bin/pip install -r requirements-dev.txt && .venv/bin/pytest
```

iOS tests:

```sh
xcodebuild test -project ios/HealthSync.xcodeproj -scheme HealthSync \
  -destination "platform=iOS Simulator,name=iPhone 16"
```
