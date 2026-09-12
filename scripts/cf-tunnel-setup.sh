#!/usr/bin/env bash
# Creates (or updates) the Cloudflare Tunnel and DNS record for one environment. Safe to re-run: an existing
# tunnel and DNS record are reused. Writes the tunnel token to deploy/.env.<env>.tunnel for the cloudflared
# container; the API token itself never leaves this Mac.
#
#   bash scripts/cf-tunnel-setup.sh test
#   bash scripts/cf-tunnel-setup.sh prod
set -euo pipefail

ROOT="/Users/stephen/Documents/Code/Claude Code/HealthSync"
ENV_NAME="${1:-}"
ZONE="sunspinner.ca"
API="https://api.cloudflare.com/client/v4"

case "$ENV_NAME" in
  test) PUBLIC_HOST="healthsync-test.sunspinner.ca"; SERVICE="http://healthsync-test:8000" ;;
  prod) PUBLIC_HOST="healthsync.sunspinner.ca";      SERVICE="http://healthsync:8000" ;;
  *) echo "usage: bash scripts/cf-tunnel-setup.sh test|prod" >&2; exit 2 ;;
esac
TUNNEL_NAME="healthsync-$ENV_NAME"
CF_ENV="$ROOT/deploy/.env.cloudflare"
TUNNEL_ENV="$ROOT/deploy/.env.$ENV_NAME.tunnel"

if [ ! -f "$CF_ENV" ]; then
  echo "Missing deploy/.env.cloudflare (see deploy/cloudflare.env.example)" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CF_ENV"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is not set in deploy/.env.cloudflare}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is not set in deploy/.env.cloudflare}"

auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

cf() { # method path [json-body]
  local out
  if [ $# -ge 3 ]; then out=$(curl -4 -sS -X "$1" "${auth[@]}" "$API$2" --data "$3")
  else out=$(curl -4 -sS -X "$1" "${auth[@]}" "$API$2"); fi
  if [ "$(jq -r .success <<<"$out")" != "true" ]; then
    echo "Cloudflare API error on $1 $2:" >&2
    jq .errors <<<"$out" >&2
    exit 1
  fi
  jq .result <<<"$out"
}

echo "==> Zone $ZONE"
ZONE_ID=$(cf GET "/zones?name=$ZONE" | jq -r '.[0].id // empty')
[ -n "$ZONE_ID" ] || { echo "Zone $ZONE not found for this token" >&2; exit 1; }

echo "==> Tunnel $TUNNEL_NAME"
TUNNEL_ID=$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" | jq -r '.[0].id // empty')
if [ -z "$TUNNEL_ID" ]; then
  TUNNEL_ID=$(cf POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel" \
    "{\"name\":\"$TUNNEL_NAME\",\"config_src\":\"cloudflare\"}" | jq -r .id)
  echo "  created $TUNNEL_ID"
else
  echo "  exists  $TUNNEL_ID"
fi

echo "==> Route $PUBLIC_HOST -> $SERVICE"
cf PUT "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  "{\"config\":{\"ingress\":[{\"hostname\":\"$PUBLIC_HOST\",\"service\":\"$SERVICE\"},{\"service\":\"http_status:404\"}]}}" \
  | jq -r '"  version \(.version)"'

echo "==> DNS CNAME $PUBLIC_HOST"
body="{\"type\":\"CNAME\",\"name\":\"$PUBLIC_HOST\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}"
RECORD_ID=$(cf GET "/zones/$ZONE_ID/dns_records?type=CNAME&name=$PUBLIC_HOST" | jq -r '.[0].id // empty')
if [ -z "$RECORD_ID" ]; then
  cf POST "/zones/$ZONE_ID/dns_records" "$body" | jq -r '"  created \(.name)"'
else
  cf PUT "/zones/$ZONE_ID/dns_records/$RECORD_ID" "$body" | jq -r '"  updated \(.name)"'
fi

echo "==> Tunnel token -> deploy/.env.$ENV_NAME.tunnel"
TOKEN=$(cf GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | jq -r .)
umask 077
printf 'TUNNEL_TOKEN=%s\n' "$TOKEN" > "$TUNNEL_ENV"
echo "==> Done"
