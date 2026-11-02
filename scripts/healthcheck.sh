#!/usr/bin/env bash
# Check host resources, container health and the app's /health and /ready
# endpoints. Appends a dated report to $LOG_DIR/healthcheck.log and exits
# non-zero if anything failed (so cron/CI can alert on it).
#
# Usage: scripts/healthcheck.sh
# Cron:  */5 * * * * /opt/ultradoc/app/scripts/healthcheck.sh >/dev/null 2>&1
set -uo pipefail   # no -e: run every check, then report

export SCRIPT_NAME=healthcheck
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

: "${DISK_MAX_PERCENT:=85}"
: "${MEM_MIN_MB:=200}"
: "${DISK_PATH:=/}"
: "${HEALTH_LOG:=$LOG_DIR/healthcheck.log}"

failures=0
report=()

check() {
  # check <name> <ok|FAIL> <detail>
  report+=("$(printf '  %-28s %-4s %s' "$1" "$2" "$3")")
  [[ "$2" == "ok" ]] || failures=$((failures + 1))
}

# ---- Disk ----
disk_pct="$(df -P "$DISK_PATH" | awk 'NR==2 {gsub("%", "", $5); print $5}')"
if [[ -n "$disk_pct" && "$disk_pct" -lt "$DISK_MAX_PERCENT" ]]; then
  check "disk $DISK_PATH" ok "${disk_pct}% used (limit ${DISK_MAX_PERCENT}%)"
else
  check "disk $DISK_PATH" FAIL "${disk_pct:-?}% used (limit ${DISK_MAX_PERCENT}%)"
fi

# ---- Memory ----
mem_avail_mb="$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)"
if [[ -n "$mem_avail_mb" && "$mem_avail_mb" -ge "$MEM_MIN_MB" ]]; then
  check "memory" ok "${mem_avail_mb} MB available (min ${MEM_MIN_MB} MB)"
else
  check "memory" FAIL "${mem_avail_mb:-?} MB available (min ${MEM_MIN_MB} MB)"
fi

# ---- Containers ----
: "${RETRY_WAIT:=35}"
container_status() {
  docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$1" 2>/dev/null || echo "missing"
}
for name in "$API_CONTAINER" "$WEB_CONTAINER" "$NGINX_CONTAINER"; do
  status="$(container_status "$name")"
  # One re-check before failing: a probe may simply not have run yet (e.g.
  # Docker marks a container unhealthy while backup.sh has it paused).
  if [[ "$status" == running/* && "$status" != "running/healthy" ]]; then
    sleep "$RETRY_WAIT"
    status="$(container_status "$name")"
  fi
  if [[ "$status" == "running/healthy" ]]; then
    check "container $name" ok "$status"
  else
    check "container $name" FAIL "$status"
  fi
done

# ---- HTTP endpoints (through nginx, like a real user) ----
for path in /api/health /api/ready; do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$APP_URL$path" 2>/dev/null)"
  if [[ "$code" == "200" ]]; then
    check "GET $path" ok "HTTP $code"
  else
    check "GET $path" FAIL "HTTP ${code:-000}"
  fi
done

# ---- Report ----
summary="OK"
(( failures > 0 )) && summary="FAIL ($failures check(s) failed)"

output="$(log "$summary"; printf '%s\n' "${report[@]}")"
echo "$output"
if mkdir -p "$(dirname "$HEALTH_LOG")" 2>/dev/null && echo "$output" >>"$HEALTH_LOG" 2>/dev/null; then
  :
else
  echo "warning: could not write $HEALTH_LOG" >&2
fi

(( failures == 0 ))
