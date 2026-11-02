#!/usr/bin/env bash
# Shared helpers for backup.sh, restore.sh and healthcheck.sh. Source, don't run.
#
# Settings come from (later wins):
#   1. the defaults below
#   2. $ULTRADOC_ENV (default /opt/ultradoc/ultradoc.env), see ultradoc.env.example
#   3. variables already exported in the calling environment

# Remember anything the caller exported so the config file can't override it.
_caller_env="$(export -p)"

ULTRADOC_ENV="${ULTRADOC_ENV:-/opt/ultradoc/ultradoc.env}"
if [[ -r "$ULTRADOC_ENV" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ULTRADOC_ENV"
  set +a
fi
eval "$_caller_env"
unset _caller_env

: "${ULTRADOC_HOME:=/opt/ultradoc}"
: "${NAME_PREFIX:=ultradoc}"
: "${DATA_VOLUME:=${NAME_PREFIX}_data}"
: "${API_CONTAINER:=${NAME_PREFIX}-api}"
: "${WEB_CONTAINER:=${NAME_PREFIX}-web}"
: "${NGINX_CONTAINER:=${NAME_PREFIX}-nginx}"
: "${BACKUP_DIR:=$ULTRADOC_HOME/backups}"
: "${LOG_DIR:=$ULTRADOC_HOME/logs}"
: "${APP_URL:=https://localhost}"
: "${S3_ENDPOINT:=http://127.0.0.1:4566}"
: "${S3_BUCKET:=ultradoc-backups}"
: "${S3_PREFIX:=backups/}"
: "${AWS_DEFAULT_REGION:=us-east-1}"
# Small image used to read/write the data volume.
: "${HELPER_IMAGE:=alpine:3.20}"
export AWS_DEFAULT_REGION

log() {
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SCRIPT_NAME:-ultradoc}" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# aws CLI against the configured (LocalStack) endpoint.
s3() {
  aws --endpoint-url "$S3_ENDPOINT" s3 "$@"
}

# Wait until a container reports healthy. Usage: wait_healthy <name> [timeout_s]
wait_healthy() {
  local name="$1" timeout="${2:-120}" waited=0 status
  while (( waited < timeout )); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo missing)"
    [[ "$status" == "healthy" ]] && return 0
    sleep 3
    waited=$(( waited + 3 ))
  done
  log "container $name not healthy after ${timeout}s (last status: $status)"
  return 1
}
