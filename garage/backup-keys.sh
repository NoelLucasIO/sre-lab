#!/usr/bin/env bash
# Garage keys and local retention for the Nightscout backups (ADR 0010). Run once as nlucas on
# fedora, from the repo; idempotent. Uses sudo for the one file that belongs to gh-runner.
#
#   ns-backup-writer  write-only on bucket `backups` -> ~/.config/sre-lab/ns-backup.env
#                     (ns-backup.timer; add HC_PING_URL to that file by hand)
#   ns-backup-reader  read-only on bucket `backups`  -> /var/lib/gh-runner/.config/sre-lab/garage-backup-reader.env
#                     (the `offsite` job of .github/workflows/backup.yml)
#   Retention: objects under nightscout/live/ expire after 14 days, set with the bucket's owner key
#   (~/.config/garage/backups.env, from garage-bootstrap.sh). The S3 copy keeps 365 days.
#
# Existing credential files are never overwritten: to rotate, delete the key in Garage and the
# file, then re-run.
set -euo pipefail

BUCKET=backups
ENDPOINT=http://127.0.0.1:3900
RETENTION_DAYS=14
WRITER_ENV="$HOME/.config/sre-lab/ns-backup.env"
READER_DIR=/var/lib/gh-runner/.config/sre-lab
READER_ENV="$READER_DIR/garage-backup-reader.env"
OWNER_ENV="$HOME/.config/garage/backups.env"
G=(podman exec -e RUST_LOG=warn garage /garage)

log() { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31mERR\e[0m %s\n' "$*" >&2; exit 1; }

[[ $(id -un) == nlucas ]] || die "run as nlucas"
"${G[@]}" bucket info "$BUCKET" >/dev/null 2>&1 || die "bucket $BUCKET missing: run garage-bootstrap.sh first"

# key NAME PERMISSION: create if missing, then grant exactly that one permission on the bucket.
key() {
  "${G[@]}" key info "$1" >/dev/null 2>&1 || { log "Key $1"; "${G[@]}" key create "$1" >/dev/null; }
  "${G[@]}" bucket deny --read --write --owner "$BUCKET" --key "$1" >/dev/null
  "${G[@]}" bucket allow "$2" "$BUCKET" --key "$1" >/dev/null
}
# envfile NAME: the key's ID and secret in the format ns-backup.sh / offsite.sh read.
envfile() {
  local info
  info=$("${G[@]}" key info "$1" --show-secret)
  awk -F': *' '/Key ID/ {i = $2} /Secret key/ {s = $2} END {
    if (i == "" || s == "") exit 1
    printf "GARAGE_ACCESS_KEY_ID=%s\nGARAGE_SECRET_ACCESS_KEY=%s\n", i, s }' <<<"$info" || die "could not parse key $1"
}

key ns-backup-writer --write
key ns-backup-reader --read

if [[ ! -s $WRITER_ENV ]]; then
  log "Writing $WRITER_ENV"
  install -d -m 0700 "$(dirname "$WRITER_ENV")"
  (umask 077; { envfile ns-backup-writer; echo "HC_PING_URL="; } >"$WRITER_ENV")
fi

if ! sudo test -s "$READER_ENV"; then
  log "Writing $READER_ENV (owner gh-runner)"
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  envfile ns-backup-reader >"$tmp"
  sudo install -d -o gh-runner -g gh-runner -m 0700 "$READER_DIR"
  sudo install -o gh-runner -g gh-runner -m 0600 "$tmp" "$READER_ENV"
fi

log "Retention: nightscout/live/ expires after $RETENTION_DAYS days"
(
  set -a
  # shellcheck source=/dev/null
  source "$OWNER_ENV"
  set +a
  export AWS_DEFAULT_REGION=garage AWS_EC2_METADATA_DISABLED=true \
    AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  aws --endpoint-url "$ENDPOINT" s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
    --lifecycle-configuration "{\"Rules\":[{\"ID\":\"nightscout-live\",\"Status\":\"Enabled\",\"Filter\":{\"Prefix\":\"nightscout/live/\"},\"Expiration\":{\"Days\":$RETENTION_DAYS},\"AbortIncompleteMultipartUpload\":{\"DaysAfterInitiation\":1}}]}"
  aws --endpoint-url "$ENDPOINT" s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --output text
)

"${G[@]}" bucket info "$BUCKET" | sed -n '/KEYS FOR THIS BUCKET/,$p'
echo "Next: put the healthchecks.io ping URL for \"sre-lab backup dump\" in $WRITER_ENV (HC_PING_URL=)."
