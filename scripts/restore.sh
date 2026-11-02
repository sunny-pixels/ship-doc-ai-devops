#!/usr/bin/env bash
# Restore the data volume from a backup made by backup.sh.
#
# Usage:
#   scripts/restore.sh --list                 # show local and S3 backups
#   scripts/restore.sh latest                 # newest backup in S3
#   scripts/restore.sh <file.tar.gz>          # a local archive
#   scripts/restore.sh s3:<name.tar.gz>       # a specific S3 object
# Add -y to skip the confirmation prompt.
#
# The API is stopped while the volume is replaced, then started and checked.
set -euo pipefail

export SCRIPT_NAME=restore
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker aws sha256sum

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

assume_yes=false
target=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) assume_yes=true ;;
    -h|--help) usage ;;
    --list)
      echo "Local ($BACKUP_DIR):"
      ls -1t "$BACKUP_DIR"/"${NAME_PREFIX}"-data-*.tar.gz 2>/dev/null || echo "  (none)"
      echo "S3 (s3://$S3_BUCKET/$S3_PREFIX):"
      s3 ls "s3://$S3_BUCKET/$S3_PREFIX" | grep '\.tar\.gz$' || echo "  (none)"
      exit 0
      ;;
    *) target="$arg" ;;
  esac
done
[[ -n "$target" ]] || usage

mkdir -p "$BACKUP_DIR"
cleanup_files=()
trap 'rm -f -- "${cleanup_files[@]}"' EXIT

# Fetch an archive (and its checksum) from S3 into a temp file; sets $archive.
# (Not echoed back via $(...): that would capture log output and lose the
# cleanup list in a subshell.)
fetch_s3() {
  local name="$1" dest
  dest="$(mktemp "$BACKUP_DIR/restore-XXXXXX.tar.gz")"
  cleanup_files+=("$dest" "$dest.sha256")
  s3 cp --only-show-errors "s3://$S3_BUCKET/${S3_PREFIX}${name}" "$dest"
  if s3 cp --only-show-errors "s3://$S3_BUCKET/${S3_PREFIX}${name}.sha256" "$dest.sha256" 2>/dev/null; then
    [[ "$(sha256sum "$dest" | awk '{print $1}')" == "$(cat "$dest.sha256")" ]] \
      || die "checksum mismatch for $name"
    log "checksum OK"
  fi
  archive="$dest"
}

case "$target" in
  latest)
    name="$(s3 ls "s3://$S3_BUCKET/$S3_PREFIX" | awk '{print $4}' | grep '\.tar\.gz$' | sort | tail -n 1)"
    [[ -n "$name" ]] || die "no backups found in s3://$S3_BUCKET/$S3_PREFIX"
    log "latest S3 backup: $name"
    fetch_s3 "$name"
    ;;
  s3:*)
    fetch_s3 "${target#s3:}"
    ;;
  *)
    [[ -f "$target" ]] || die "file not found: $target"
    archive="$target"
    ;;
esac

gzip -t "$archive" || die "$archive is not a valid gzip archive"

if [[ "$assume_yes" != true ]]; then
  read -r -p "Replace ALL data in volume $DATA_VOLUME with $(basename "$archive")? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "aborted"
fi

log "stopping $API_CONTAINER"
docker stop "$API_CONTAINER" >/dev/null 2>&1 || log "$API_CONTAINER was not running"

log "restoring into volume $DATA_VOLUME"
# Wipe (including dotfiles) and extract from stdin; numeric owners keep the
# files owned by the API's uid 10001.
docker run --rm -i -v "$DATA_VOLUME":/data "$HELPER_IMAGE" \
  sh -c 'find /data -mindepth 1 -delete && tar -xzf - --numeric-owner -C /data' <"$archive"

log "starting $API_CONTAINER"
docker start "$API_CONTAINER" >/dev/null
wait_healthy "$API_CONTAINER" 120 || die "API did not become healthy after restore"

if curl -fsk --max-time 10 "$APP_URL/api/ready" >/dev/null; then
  log "restore complete: $APP_URL/api/ready OK"
else
  die "API is up but $APP_URL/api/ready failed"
fi
