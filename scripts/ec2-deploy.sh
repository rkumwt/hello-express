#!/usr/bin/env bash
# Runs ON the EC2 instance (sent by GitHub Actions through AWS SSM Run Command).
# Pulls the given image from ECR, swaps the running container, health-checks it,
# and rolls back to the previous image if the health check fails.
#
# Usage: ec2-deploy.sh <image-uri> <aws-region> [host-port]
set -euo pipefail

IMAGE="${1:?image uri required}"
REGION="${2:?aws region required}"
HOST_PORT="${3:-80}"
NAME="hello-express"
REGISTRY="${IMAGE%%/*}"

log() { echo "[deploy] $*"; }

run_container() {
  docker run -d \
    --name "$NAME" \
    --restart unless-stopped \
    -p "${HOST_PORT}:3000" \
    -e NODE_ENV=production \
    "$1" >/dev/null
}

healthy() {
  for _ in $(seq 1 15); do
    if curl -fsS "http://localhost:${HOST_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

log "Logging in to ${REGISTRY}"
aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

log "Pulling ${IMAGE}"
docker pull --quiet "$IMAGE"

PREVIOUS="$(docker inspect --format '{{.Config.Image}}' "$NAME" 2>/dev/null || true)"
log "Previous image: ${PREVIOUS:-<none>}"

docker rm -f "$NAME" >/dev/null 2>&1 || true
log "Starting ${IMAGE} on port ${HOST_PORT}"
run_container "$IMAGE"

if healthy; then
  log "Health check passed"
  # Free disk space: remove images not used by any container and older than 7 days.
  docker image prune -af --filter "until=168h" >/dev/null || true
  exit 0
fi

log "Health check FAILED — container logs:"
docker logs --tail 50 "$NAME" || true
docker rm -f "$NAME" >/dev/null 2>&1 || true

if [ -n "$PREVIOUS" ]; then
  log "Rolling back to ${PREVIOUS}"
  run_container "$PREVIOUS"
  healthy && log "Rollback healthy" || log "Rollback ALSO unhealthy"
fi
exit 1
