#!/usr/bin/env bash
# Build the server image on this Mac (amd64), ship it to the Docker host, recreate the containers, and check
# that the server answers on the LAN and through Cloudflare. A single command so it only needs approving once.
#
#   bash scripts/deploy.sh test
#   bash scripts/deploy.sh prod
set -euo pipefail

ROOT="/Users/stephen/Documents/Code/Claude Code/HealthSync"
ENV_NAME="${1:-}"

case "$ENV_NAME" in
  test) PUBLIC_HOST="healthsync-test.sunspinner.ca"; LAN_PORT=3031 ;;
  prod) PUBLIC_HOST="healthsync.sunspinner.ca";      LAN_PORT=3030 ;;
  *) echo "usage: bash scripts/deploy.sh test|prod" >&2; exit 2 ;;
esac

HOST="stephen@192.168.68.73"
BUILD_CTX="desktop-linux"
DEPLOY_CTX="shared-docker-server"
IMAGE="healthsync-server:$ENV_NAME"
COMPOSE="$ROOT/deploy/docker-compose.$ENV_NAME.yml"

for file in "$ROOT/deploy/.env.$ENV_NAME" "$ROOT/deploy/.env.$ENV_NAME.tunnel"; do
  if [ ! -f "$file" ]; then
    echo "Missing $file. Run scripts/db.sh $ENV_NAME and scripts/cf-tunnel-setup.sh $ENV_NAME first." >&2
    exit 1
  fi
done

echo "==> Building $IMAGE (linux/amd64)"
docker --context "$BUILD_CTX" build --platform linux/amd64 -t "$IMAGE" "$ROOT/server"

echo "==> Shipping $IMAGE to $HOST"
docker --context "$BUILD_CTX" save "$IMAGE" | ssh "$HOST" docker load

echo "==> Recreating containers"
docker --context "$DEPLOY_CTX" compose -f "$COMPOSE" up -d --no-build --force-recreate

echo "==> Removing dangling images on the host"
ssh "$HOST" docker image prune -f > /dev/null

echo "==> Health"
lan=000
for _ in $(seq 1 20); do
  lan=$(curl -s -o /dev/null -w "%{http_code}" "http://192.168.68.73:$LAN_PORT/healthz" || true)
  [ "$lan" = "200" ] && break
  sleep 2
done
echo "  LAN      http://192.168.68.73:$LAN_PORT/healthz -> $lan"

public=000
for _ in $(seq 1 15); do
  public=$(curl -s -o /dev/null -w "%{http_code}" "https://$PUBLIC_HOST/healthz" || true)
  [ "$public" = "200" ] && break
  sleep 2
done
echo "  Public   https://$PUBLIC_HOST/healthz -> $public"
metadata=$(curl -s -o /dev/null -w "%{http_code}" "https://$PUBLIC_HOST/.well-known/oauth-protected-resource/mcp" || true)
echo "  OAuth    https://$PUBLIC_HOST/.well-known/oauth-protected-resource/mcp -> $metadata"

[ "$lan" = "200" ] && [ "$public" = "200" ] && [ "$metadata" = "200" ]
echo "==> Done"
