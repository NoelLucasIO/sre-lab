#!/usr/bin/env bash
# Moves Nightscout dumps between tiers for the `backup` workflow (ADR 0010).
#
#   offsite.sh garage-get DIR   Newest dump in Garage -> DIR (fedora runner, Garage read-only key
#                               from $GARAGE_READER_ENV). Used by the nightly offsite job.
#   offsite.sh s3-put DIR       DIR -> S3 under the same key, with the job's AWS credentials (role
#                               sre-lab-backup-writer: PutObject on the prefix, nothing else). S3
#                               verifies the SHA-256 on arrival; If-None-Match makes a re-run a no-op.
#   offsite.sh s3-get DIR       Newest dump in S3 -> DIR (role sre-lab-restore-reader). Used by the
#                               weekly restore test and by a DR restore.
#
# Every *-get refuses a dump older than $MAX_AGE_HOURS (the RPO guard) and re-checks its SHA-256
# against the object metadata. DIR gets: dump, key, sha256, counts-min, counts-max, mongo-version.
set -euo pipefail

cmd=${1:?usage: offsite.sh garage-get|s3-put|s3-get DIR}
dir=${2:?usage: offsite.sh garage-get|s3-put|s3-get DIR}
PREFIX=${PREFIX:-nightscout/live/}
MAX_AGE_HOURS=${MAX_AGE_HOURS:-26}

die() { echo "offsite: $*" >&2; exit 1; }

# get BUCKET aws-args...: newest object under PREFIX (keys embed the UTC time, so name order is
# time order), age-checked, downloaded, verified.
get() {
  local bucket=$1
  shift
  local aws=("$@") key ts age_h
  mkdir -p "$dir"
  key=$("${aws[@]}" s3api list-objects-v2 --bucket "$bucket" --prefix "$PREFIX" \
    --query 'Contents[].Key' --output text | tr '\t' '\n' | grep -E '\.archive\.gz$' | sort | tail -1 || true)
  [[ -n $key ]] || die "no dump under $bucket/$PREFIX"
  ts=$(sed -E 's/.*-([0-9]{8}T[0-9]{6}Z)\.archive\.gz$/\1/' <<<"$key")
  age_h=$((($(date -u +%s) - $(date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z" +%s)) / 3600))
  ((age_h <= MAX_AGE_HOURS)) || die "newest dump $key is ${age_h} h old (limit ${MAX_AGE_HOURS} h): RPO missed"

  "${aws[@]}" s3api get-object --bucket "$bucket" --key "$key" "$dir/dump" >"$dir/get.json"
  python3 - "$dir" <<'EOF'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
meta = json.loads((d / "get.json").read_text()).get("Metadata", {})
for k in ("sha256", "counts-min", "counts-max", "mongo-version"):
    if k not in meta:
        sys.exit(f"offsite: object metadata has no {k}")
    (d / k).write_text(meta[k] + "\n")
EOF
  echo "$key" >"$dir/key"
  [[ $(sha256sum "$dir/dump" | cut -d' ' -f1) == "$(cat "$dir/sha256")" ]] || die "SHA-256 mismatch for $key"
  echo "offsite: $key: $(stat -c %s "$dir/dump") bytes, ${age_h} h old, SHA-256 ok"
}

case $cmd in
garage-get)
  # shellcheck source=/dev/null
  source "${GARAGE_READER_ENV:?GARAGE_READER_ENV not set}"
  # Garage only: its own key and region, no AWS session, plain (non-chunked) requests.
  export AWS_ACCESS_KEY_ID=$GARAGE_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$GARAGE_SECRET_ACCESS_KEY \
    AWS_DEFAULT_REGION=garage AWS_REGION=garage AWS_EC2_METADATA_DISABLED=true \
    AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  unset AWS_SESSION_TOKEN AWS_PROFILE
  get "${GARAGE_BUCKET:-backups}" aws --endpoint-url "${GARAGE_ENDPOINT:-http://127.0.0.1:3900}"
  ;;
s3-get)
  get "${BUCKET:?BUCKET not set}" aws
  ;;
s3-put)
  key=$(cat "$dir/key")
  b64=$(openssl dgst -sha256 -binary "$dir/dump" | base64)
  meta=$(python3 -c 'import json, sys; print(json.dumps({k: open(f"{sys.argv[1]}/{k}").read().strip() for k in ("sha256", "counts-min", "counts-max", "mongo-version")}))' "$dir")
  if out=$(aws s3api put-object --bucket "${BUCKET:?BUCKET not set}" --key "$key" --body "$dir/dump" \
    --checksum-sha256 "$b64" --if-none-match '*' --content-type application/gzip --metadata "$meta" 2>&1); then
    echo "offsite: put s3://$BUCKET/$key (SHA-256 verified by S3)"
  elif grep -q PreconditionFailed <<<"$out"; then
    echo "offsite: s3://$BUCKET/$key already offsite (no-op)"
  else
    echo "$out" >&2
    die "put failed"
  fi
  ;;
*) die "unknown command $cmd" ;;
esac
