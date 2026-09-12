#!/usr/bin/env bash
# Database setup for one environment. Safe to re-run: creates the roles and database if
# missing, applies migrations not yet recorded in schema_migrations, then re-applies grants.
#
#   bash scripts/db.sh test     # healthsync_test on 192.168.68.86
#   bash scripts/db.sh prod     # healthsync_prod on 192.168.68.86
#   bash scripts/db.sh local    # local Docker Postgres on localhost:55432, for the test suite
#
# Superuser access comes from PGADMIN_URL (environment, or deploy/.env.pgadmin). Role passwords are
# generated once and kept in deploy/.env.<env>, which the server container reads. No password is ever
# passed on a command line: everything goes to psql on stdin.
set -euo pipefail

ROOT="/Users/stephen/Documents/Code/Claude Code/HealthSync"
ENV_NAME="${1:-}"

case "$ENV_NAME" in
  test)  DB_HOST="192.168.68.86:5432"; PUBLIC_URL="https://healthsync-test.sunspinner.ca" ;;
  prod)  DB_HOST="192.168.68.86:5432"; PUBLIC_URL="https://healthsync.sunspinner.ca" ;;
  local) DB_HOST="localhost:55432";    PUBLIC_URL="http://localhost:8000" ;;
  *) echo "usage: bash scripts/db.sh test|prod|local" >&2; exit 2 ;;
esac

DB="healthsync_$ENV_NAME"
OWNER="${DB}_owner"
APP="${DB}_app"
MCP="${DB}_mcp"
ENV_FILE="$ROOT/deploy/.env.$ENV_NAME"

if [ -z "${PGADMIN_URL:-}" ]; then
  if [ ! -f "$ROOT/deploy/.env.pgadmin" ]; then
    echo "Missing deploy/.env.pgadmin (see deploy/pgadmin.env.example)" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source "$ROOT/deploy/.env.pgadmin"
fi
: "${PGADMIN_URL:?PGADMIN_URL is not set}"

touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

env_get() { grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true; }
env_set() {
  grep -vE "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}
env_default() { [ -n "$(env_get "$1")" ] || env_set "$1" "$2"; }

env_default APP_DB_PASSWORD "$(openssl rand -hex 24)"
env_default MCP_DB_PASSWORD "$(openssl rand -hex 24)"
APP_PW="$(env_get APP_DB_PASSWORD)"
MCP_PW="$(env_get MCP_DB_PASSWORD)"
env_set DATABASE_URL "postgresql+psycopg://$APP:$APP_PW@$DB_HOST/$DB"
env_set MCP_DATABASE_URL "postgresql+psycopg://$MCP:$MCP_PW@$DB_HOST/$DB"
env_default PUBLIC_URL "$PUBLIC_URL"
env_default TZ "America/Edmonton"

echo "==> Roles and database $DB on $DB_HOST"
psql -X -q -d "$PGADMIN_URL" <<SQL
\set ON_ERROR_STOP on
SET client_min_messages = warning;
\set db '$DB'
\set owner '$OWNER'
\set app '$APP'
\set mcp '$MCP'
\set app_pw '$APP_PW'
\set mcp_pw '$MCP_PW'

SELECT format('CREATE ROLE %I NOLOGIN', :'owner') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'owner') \gexec
SELECT format('CREATE ROLE %I LOGIN', :'app') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app') \gexec
SELECT format('CREATE ROLE %I LOGIN', :'mcp') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'mcp') \gexec
ALTER ROLE :"app" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD :'app_pw';
ALTER ROLE :"mcp" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD :'mcp_pw';
ALTER ROLE :"mcp" SET default_transaction_read_only = on;

SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'owner') WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"app", :"mcp";
-- Timestamps are stored as absolute instants (timestamptz) but every session shows them in local time.
ALTER DATABASE :"db" SET timezone TO 'America/Edmonton';

\connect :db
ALTER SCHEMA public OWNER TO :"owner";
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"app", :"mcp";

SET ROLE :"owner";
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     TEXT PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

echo "==> Migrations"
{
  printf '\\set ON_ERROR_STOP on\n'
  printf '\\connect %s\n' "$DB"
  printf 'SET ROLE %s;\n' "$OWNER"
  for file in "$ROOT"/db/migrations/*.sql; do
    version="$(basename "$file" .sql)"
    printf "SELECT NOT EXISTS (SELECT 1 FROM schema_migrations WHERE version = '%s') AS pending \\\\gset\n" "$version"
    printf '\\if :pending\n'
    printf 'BEGIN;\n'
    printf "\\\\i '%s'\n" "$file"
    printf "INSERT INTO schema_migrations (version) VALUES ('%s');\n" "$version"
    printf 'COMMIT;\n'
    printf "\\\\echo '  applied %s'\n" "$version"
    printf '\\else\n'
    printf "\\\\echo '  up to date %s'\n" "$version"
    printf '\\endif\n'
  done
} | psql -X -q -d "$PGADMIN_URL"

echo "==> Grants and row security"
psql -X -q -d "$PGADMIN_URL" <<SQL
\set ON_ERROR_STOP on
\connect $DB
SET client_min_messages = warning;
SET ROLE $OWNER;
\set app '$APP'
\set mcp '$MCP'
\i '$ROOT/db/grants.sql'
SQL

echo "==> Done ($ENV_FILE has the connection settings)"
