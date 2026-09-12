#!/usr/bin/env bash
# Installs scripts/backup.sh on the Docker host with a nightly cron entry (03:15), plus one credentials file per
# environment set up with scripts/db.sh. Safe to re-run after adding an environment or rotating passwords.
#
#   bash scripts/install-backup.sh
set -euo pipefail

ROOT="/Users/stephen/Documents/Code/Claude Code/HealthSync"
HOST="stephen@192.168.68.73"
DB_HOST="192.168.68.86:5432"

ssh "$HOST" 'mkdir -p ~/healthsync ~/healthsync-backups && chmod 700 ~/healthsync ~/healthsync-backups'

for env_name in test prod; do
  env_file="$ROOT/deploy/.env.$env_name"
  [ -f "$env_file" ] || continue
  password="$(grep -E '^APP_DB_PASSWORD=' "$env_file" | cut -d= -f2-)"
  echo "==> Credentials for healthsync_$env_name"
  # Sent over SSH stdin so the password never appears in a command line.
  printf 'BACKUP_URL=postgresql://healthsync_%s_app:%s@%s/healthsync_%s\n' "$env_name" "$password" "$DB_HOST" "$env_name" \
    | ssh "$HOST" "umask 077 && cat > ~/healthsync/backup-$env_name.env"
done

echo "==> backup.sh"
ssh "$HOST" 'cat > ~/healthsync/backup.sh && chmod 700 ~/healthsync/backup.sh' < "$ROOT/scripts/backup.sh"

echo "==> cron (03:15 nightly)"
ssh "$HOST" '(crontab -l 2>/dev/null | grep -v "healthsync/backup.sh"; echo "15 3 * * * bash \$HOME/healthsync/backup.sh >> \$HOME/healthsync-backups/backup.log 2>&1") | crontab -'

echo "==> Test run"
ssh "$HOST" 'bash ~/healthsync/backup.sh && ls -lh ~/healthsync-backups | tail -n 5'
echo "==> Done"
