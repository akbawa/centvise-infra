#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER_FILE="$INFRA_DIR/docker/docker-compose.yml"
ENV_NAME=""
RESTART_BACKEND=false
RESTART_FRONTEND=false
FORCE_RECREATE=false

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --env <name> (--backend | --frontend | --all) [--force-recreate]
EOF
}

log() { printf '=> %s\n' "$1"; }
error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

dc() {
  docker compose --env-file "$DOCKER_ENV_FILE" -f "$DOCKER_FILE" "$@"
}

wait_for_healthy() {
  local service="$1" timeout_seconds="${2:-180}" elapsed_seconds=0 container_id="" status=""
  log "Waiting for $service to be healthy"
  while (( elapsed_seconds < timeout_seconds )); do
    container_id="$(dc ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$container_id" ]]; then
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
      case "$status" in
        healthy|running) log "$service is ready"; return 0 ;;
        unhealthy|exited|dead) error "$service is $status" ;;
      esac
    fi
    sleep 2
    elapsed_seconds=$((elapsed_seconds + 2))
  done
  error "Timed out waiting for $service to be healthy"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env=*) ENV_NAME="${1#--env=}"; shift ;;
    --env) [[ $# -ge 2 && "$2" != -* ]] || error "Environment missing after --env"; ENV_NAME="$2"; shift 2 ;;
    --backend) RESTART_BACKEND=true; shift ;;
    --frontend|--webapp) RESTART_FRONTEND=true; shift ;;
    --all|--both) RESTART_BACKEND=true; RESTART_FRONTEND=true; shift ;;
    --force-recreate) FORCE_RECREATE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1" ;;
  esac
done

[[ "$ENV_NAME" == "prod" || "$ENV_NAME" == "stag" ]] || error "Environment must be 'prod' or 'stag'."
$RESTART_BACKEND || $RESTART_FRONTEND || error "Pass --backend, --frontend, or --all."

ENV_DIR="$INFRA_DIR/environments/$ENV_NAME"
DOCKER_ENV_FILE="$ENV_DIR/docker.env"
[[ -f "$DOCKER_ENV_FILE" ]] || error "Docker env file not found: $DOCKER_ENV_FILE"
dc config --quiet

restart_service() {
  local service="$1"
  if $FORCE_RECREATE; then
    log "Recreating $service"
    dc up -d --no-deps --force-recreate "$service"
  else
    log "Restarting $service"
    dc restart "$service"
  fi
  wait_for_healthy "$service"
}

$RESTART_BACKEND && restart_service backend
$RESTART_FRONTEND && restart_service frontend
log "Restart completed for environment: $ENV_NAME"

