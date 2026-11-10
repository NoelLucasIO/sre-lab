#!/usr/bin/env bash
# ns-backup: nightly logical backup of the live Nightscout database into Garage (ADR 0010).
# Stage 1 of 2, run as nlucas on fedora by ns-backup.timer. Stage 2 (the offsite copy to S3) is
# the `offsite` job in .github/workflows/backup.yml, which reads what this writes.
#
#   mongodump inside the live pod's Mongo container (Mongo is never published on a port)
#     -> one gzip archive, its SHA-256, and per-collection document counts taken just before and
#        just after the dump. Mongo 4.4 without a replica set has no point-in-time dump, so a
#        restore is correct when every count lands between the two.
#     -> Garage bucket `backups`, key nightscout/live/YYYY/MM/DD/nightscout-live-<UTC>.archive.gz,
#        hash and counts as object metadata. The Garage key is write-only: it cannot list, read
#        or delete.
#     -> healthchecks.io check "sre-lab backup dump": start, then success or fail with the reason.
#
# Config: ~/.config/sre-lab/ns-backup.env (0600): GARAGE_ACCESS_KEY_ID, GARAGE_SECRET_ACCESS_KEY
# (written by garage/backup-keys.sh) and HC_PING_URL (added by hand).
set -euo pipefail
umask 077

CONF=${NS_BACKUP_CONF:-$HOME/.config/sre-lab/ns-backup.env}
ENDPOINT=${GARAGE_ENDPOINT:-http://127.0.0.1:3900}
BUCKET=${GARAGE_BUCKET:-backups}
PREFIX=${NS_BACKUP_PREFIX:-nightscout/live}
CONTAINER=${MONGO_CONTAINER:-nightscout-mongo}
DB=nightscout

# shellcheck source=/dev/null
source "$CONF"
: "${GARAGE_ACCESS_KEY_ID:?not set in $CONF}" "${GARAGE_SECRET_ACCESS_KEY:?not set in $CONF}" "${HC_PING_URL:?not set in $CONF}"

hc() { curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "${2:-}" "$HC_PING_URL$1" || true; }
fail() { echo "ns-backup: FAILED: $1" >&2; hc /fail "$1"; exit 1; }
trap 'fail "command failed at line $LINENO"' ERR

# "collection:count/collection:count/..." for every collection, sorted. Same format as
# backup/test.sh and backup/restore-check.sh.
counts() {
  podman exec "$CONTAINER" mongo --quiet --eval \
    "var d=db.getSiblingDB('$DB'); print(d.getCollectionNames().sort().map(c => c + ':' + d.getCollection(c).countDocuments({})).join('/'))"
}

hc /start
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ts=$(date -u +%Y%m%dT%H%M%SZ)
key="$PREFIX/${ts:0:4}/${ts:4:2}/${ts:6:2}/nightscout-live-$ts.archive.gz"

min=$(counts)
podman exec "$CONTAINER" mongodump --quiet --db "$DB" --archive --gzip >"$work/dump"
max=$(counts)

gzip -t "$work/dump"
size=$(stat -c %s "$work/dump")
((size > 1024)) || fail "dump is only $size bytes"
sha=$(sha256sum "$work/dump" | cut -d' ' -f1)
mongo_version=$(podman exec "$CONTAINER" mongod --version | awk 'NR == 1 {print $3}')

meta=$(printf '{"sha256":"%s","counts-min":"%s","counts-max":"%s","mongo-version":"%s","source":"%s/%s"}' \
  "$sha" "$min" "$max" "$mongo_version" "$(hostname -s)" "$CONTAINER")

# Garage takes plain PutObject; the CLI's default flexible checksums (aws-chunked trailers) are
# turned off for it. Integrity is the sha256 in the metadata, re-checked by every reader.
env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
  AWS_ACCESS_KEY_ID="$GARAGE_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$GARAGE_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION=garage AWS_EC2_METADATA_DISABLED=true \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
  aws --endpoint-url "$ENDPOINT" s3api put-object --bucket "$BUCKET" --key "$key" \
  --body "$work/dump" --content-type application/gzip --metadata "$meta" >/dev/null

msg="$key ($size bytes, sha256 $sha, counts $max)"
echo "ns-backup: ok: $msg"
hc "" "$msg"
