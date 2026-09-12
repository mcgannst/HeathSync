#!/usr/bin/env bash
# Nightly database backups. Runs ON THE DOCKER HOST from cron, installed by scripts/install-backup.sh.
# Dumps each environment that has ~/healthsync/backup-<env>.env with a one-shot postgres:14 container and keeps
# 30 days of dumps in ~/healthsync-backups. Restore with pg_restore.
set -euo pipefail
export TZ="America/Edmonton"

CONFIG_DIR="$HOME/healthsync"
BACKUP_DIR="$HOME/healthsync-backups"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

for env_name in prod test; do
  env_file="$CONFIG_DIR/backup-$env_name.env"
  [ -f "$env_file" ] || continue

  target="$BACKUP_DIR/healthsync_$env_name-$(date +%Y-%m-%d).dump"
  # --enable-row-security: tables use row security, and the API role's policy lets it read every row.
  docker run --rm --network host --env-file "$env_file" postgres:14 \
    sh -c 'pg_dump --enable-row-security --format=custom "$BACKUP_URL"' > "$target.partial"
  mv "$target.partial" "$target"
  chmod 600 "$target"
  echo "$(date -Iseconds) backed up healthsync_$env_name ($(du -h "$target" | cut -f1))"

  find "$BACKUP_DIR" -name "healthsync_$env_name-*.dump" -mtime +30 -delete
done
