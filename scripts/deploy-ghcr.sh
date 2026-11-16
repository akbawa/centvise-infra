#!/usr/bin/env bash

# Never inherit xtrace: registry credentials must not appear in logs.
set +x
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANAGER_ROOT="$(cd "$INFRA_DIR/.." && pwd)"
DOCKER_FILE="$INFRA_DIR/docker/docker-compose.yml"
ENV_NAME=""
CONTAINER_REGISTRY=""
DOCKER_CONFIG_DIR=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --env <prod|stag>
  $(basename "$0") <prod|stag>

Pulls the configured moving tags from GHCR and force-recreates both services.
Registry credentials are read from environments/<env>/docker.env.
EOF
}

log() { printf '=> %s\n' "$1"; }
error() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

read_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v key="$key" '$1 == key { value=substr($0, index($0, "=") + 1); sub(/\r$/, "", value); print value; exit }' "$file"
}

file_mode() {
  local file="$1" mode=""
  if mode="$(stat -c '%a' "$file" 2>/dev/null)"; then
    printf '%s' "$mode"
  elif mode="$(stat -f '%Lp' "$file" 2>/dev/null)"; then
    printf '%s' "$mode"
  else
    return 1
  fi
}

cleanup() {
  [[ -n "$CONTAINER_REGISTRY" ]] && docker logout "$CONTAINER_REGISTRY" >/dev/null 2>&1 || true
  if [[ "$DOCKER_CONFIG_DIR" == /tmp/centvise-docker-config.* && -d "$DOCKER_CONFIG_DIR" ]]; then
    rm -rf -- "$DOCKER_CONFIG_DIR"
  fi
}

dc() {
  docker compose --env-file "$DOCKER_ENV_FILE" -f "$DOCKER_FILE" "$@"
}

prepare_storage() {
  local storage_root="$MANAGER_ROOT/data/$ENV_NAME/backend-files"
  local expected_owner="${BACKEND_UID}:${BACKEND_GID}"
  local actual_owner=""

  [[ -d "$storage_root" ]] || \
    error "Storage root does not exist: $storage_root. Create it as an administrator and assign it to $expected_owner."

  if actual_owner="$(stat -c '%u:%g' "$storage_root" 2>/dev/null)"; then
    :
  elif actual_owner="$(stat -f '%u:%g' "$storage_root" 2>/dev/null)"; then
    :
  else
    error "Could not determine storage ownership: $storage_root"
  fi

  [[ "$actual_owner" == "$expected_owner" ]] || \
    error "Storage owner is $actual_owner but backend runs as $expected_owner. Fix ownership for $storage_root or update BACKEND_UID/BACKEND_GID."
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
    --env)
      [[ $# -ge 2 && "$2" != -* ]] || error "Environment missing after --env"
      ENV_NAME="$2"
      shift 2
      ;;
    prod|stag)
      [[ -z "$ENV_NAME" ]] || error "Environment supplied more than once"
      ENV_NAME="$1"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1" ;;
  esac
done

[[ "$ENV_NAME" == "prod" || "$ENV_NAME" == "stag" ]] || error "Environment must be 'prod' or 'stag'."

ENV_DIR="$INFRA_DIR/environments/$ENV_NAME"
DOCKER_ENV_FILE="$ENV_DIR/docker.env"
BACKEND_ENV_FILE="$ENV_DIR/backend.env"
[[ -f "$DOCKER_FILE" ]] || error "Compose file not found: $DOCKER_FILE"
[[ -f "$DOCKER_ENV_FILE" ]] || error "Docker env file not found: $DOCKER_ENV_FILE"
[[ -f "$BACKEND_ENV_FILE" ]] || error "Backend env file not found: $BACKEND_ENV_FILE"

DOCKER_ENV_MODE="$(file_mode "$DOCKER_ENV_FILE")" || error "Could not read permissions for $DOCKER_ENV_FILE"
[[ "$DOCKER_ENV_MODE" == "600" || "$DOCKER_ENV_MODE" == "400" ]] || \
  error "$DOCKER_ENV_FILE contains a registry token and must have mode 600 or 400 (current: $DOCKER_ENV_MODE)."

BACKEND_ENV_MODE="$(file_mode "$BACKEND_ENV_FILE")" || error "Could not read permissions for $BACKEND_ENV_FILE"
[[ "$BACKEND_ENV_MODE" == "600" || "$BACKEND_ENV_MODE" == "400" ]] || \
  error "$BACKEND_ENV_FILE contains application secrets and must have mode 600 or 400 (current: $BACKEND_ENV_MODE)."

CONTAINER_REGISTRY="$(read_env_value "$DOCKER_ENV_FILE" CONTAINER_REGISTRY)"
CONTAINER_REGISTRY_USER="$(read_env_value "$DOCKER_ENV_FILE" CONTAINER_REGISTRY_USER)"
GHCR_PULL_TOKEN="$(read_env_value "$DOCKER_ENV_FILE" GHCR_PULL_TOKEN)"
CONFIGURED_ENV_NAME="$(read_env_value "$DOCKER_ENV_FILE" ENV_NAME)"
CONFIGURED_PROJECT_ROOT="$(read_env_value "$DOCKER_ENV_FILE" PROJECT_ROOT)"
BACKEND_UID="$(read_env_value "$DOCKER_ENV_FILE" BACKEND_UID)"
BACKEND_GID="$(read_env_value "$DOCKER_ENV_FILE" BACKEND_GID)"
BACKEND_IMAGE_TAG="$(read_env_value "$DOCKER_ENV_FILE" BACKEND_IMAGE_TAG)"
FRONTEND_IMAGE_TAG="$(read_env_value "$DOCKER_ENV_FILE" FRONTEND_IMAGE_TAG)"

[[ "$CONFIGURED_ENV_NAME" == "$ENV_NAME" ]] || error "ENV_NAME in docker.env must be '$ENV_NAME'."
[[ -n "$CONTAINER_REGISTRY" ]] || error "Set CONTAINER_REGISTRY in $DOCKER_ENV_FILE"
[[ -n "$CONTAINER_REGISTRY_USER" ]] || error "Set CONTAINER_REGISTRY_USER in $DOCKER_ENV_FILE"
[[ -n "$GHCR_PULL_TOKEN" && "$GHCR_PULL_TOKEN" != replace-* ]] || error "Set GHCR_PULL_TOKEN in $DOCKER_ENV_FILE"
[[ -n "$BACKEND_IMAGE_TAG" ]] || error "Set BACKEND_IMAGE_TAG in $DOCKER_ENV_FILE"
[[ -n "$FRONTEND_IMAGE_TAG" ]] || error "Set FRONTEND_IMAGE_TAG in $DOCKER_ENV_FILE"
[[ -d "$CONFIGURED_PROJECT_ROOT" ]] || error "PROJECT_ROOT does not exist: $CONFIGURED_PROJECT_ROOT"
[[ "$(cd "$CONFIGURED_PROJECT_ROOT" && pwd -P)" == "$(cd "$MANAGER_ROOT" && pwd -P)" ]] || \
  error "PROJECT_ROOT must point to the centvise-manager root: $MANAGER_ROOT"
[[ "$BACKEND_UID" =~ ^[0-9]+$ ]] || error "BACKEND_UID must be numeric."
[[ "$BACKEND_GID" =~ ^[0-9]+$ ]] || error "BACKEND_GID must be numeric."

for required_key in \
  HOST PORT WHITELISTED_DOMAIN CLIENT_URL MONGO_URI JWT_SECRET \
  BREVO_API_KEY EMAIL_SENDER STORAGE_MODE CENTVISE_STORAGE_ROOT \
  GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GMAIL_OAUTH_REDIRECT_URI \
  GMAIL_OAUTH_TOKEN_ENCRYPTION_KEY; do
  [[ -n "$(read_env_value "$BACKEND_ENV_FILE" "$required_key")" ]] || \
    error "Set $required_key in $BACKEND_ENV_FILE"
done

[[ "$(read_env_value "$BACKEND_ENV_FILE" HOST)" == "0.0.0.0" ]] || \
  error "HOST in $BACKEND_ENV_FILE must be 0.0.0.0 inside Docker."
[[ "$(read_env_value "$BACKEND_ENV_FILE" PORT)" == "4000" ]] || \
  error "PORT in $BACKEND_ENV_FILE must be 4000 to match the container configuration."
[[ "$(read_env_value "$BACKEND_ENV_FILE" STORAGE_MODE)" == "local" ]] || \
  error "STORAGE_MODE in $BACKEND_ENV_FILE must be local for VPS file persistence."
[[ "$(read_env_value "$BACKEND_ENV_FILE" CENTVISE_STORAGE_ROOT)" == "/var/lib/centvise" ]] || \
  error "CENTVISE_STORAGE_ROOT in $BACKEND_ENV_FILE must match the /var/lib/centvise volume target."

prepare_storage
trap cleanup EXIT

# Isolate registry credentials from the deploy user's persistent Docker config.
DOCKER_CONFIG_DIR="$(mktemp -d /tmp/centvise-docker-config.XXXXXX)"
chmod 700 "$DOCKER_CONFIG_DIR"
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

log "Logging in to $CONTAINER_REGISTRY as $CONTAINER_REGISTRY_USER"
if ! printf '%s' "$GHCR_PULL_TOKEN" | docker login "$CONTAINER_REGISTRY" -u "$CONTAINER_REGISTRY_USER" --password-stdin >/dev/null 2>&1; then
  error "Container registry login failed (output suppressed)"
fi
unset GHCR_PULL_TOKEN

dc config --quiet

log "Checking GHCR and pulling backend:$BACKEND_IMAGE_TAG and frontend:$FRONTEND_IMAGE_TAG"
dc pull --policy always backend frontend

log "Force-recreating backend from the pulled image"
dc up -d --no-deps --pull always --force-recreate backend
wait_for_healthy backend

log "Force-recreating frontend from the pulled image"
dc up -d --no-deps --pull always --force-recreate frontend
wait_for_healthy frontend

log "Deployment completed"
log "Environment: $ENV_NAME"
log "Backend tag: $BACKEND_IMAGE_TAG"
log "Frontend tag: $FRONTEND_IMAGE_TAG"
