#!/usr/bin/env bash
# Restore a Nightscout dump into a throwaway Mongo and prove it (ADR 0010): every collection the
# dump recorded must come back, with a document count between the counts taken just before and
# just after the dump.
#
# Usage: restore-check.sh ARCHIVE COUNTS_MIN COUNTS_MAX
#   COUNTS_*: "collection:count/collection:count/..." (object metadata counts-min / counts-max)
# Env: CTR = podman | docker (default: podman if installed), MONGO_IMAGE (default pinned below:
#      the same Mongo 4.4 build the live pod runs). The container has no network.
# Output: one line per collection, then `restore_seconds=N`. Exit 0 only if every count checks out.
set -euo pipefail

archive=$(realpath "${1:?usage: restore-check.sh ARCHIVE COUNTS_MIN COUNTS_MAX}")
min=${2:?counts-min missing}
max=${3:?counts-max missing}
MONGO_IMAGE=${MONGO_IMAGE:-docker.io/library/mongo:4.4@sha256:7250955b2354cc6ad3548b428628e441e34625caa39dd64906e85adf369e1942}
CTR=${CTR:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}

name=nsrestore-$$
mount="$archive:/in/dump:ro"
[[ $CTR == podman ]] && mount+=",Z"
trap '"$CTR" rm -f "$name" >/dev/null 2>&1 || true' EXIT

"$CTR" run -d --rm --name "$name" --network none -v "$mount" "$MONGO_IMAGE" >/dev/null
for _ in $(seq 60); do
  "$CTR" exec "$name" mongo --quiet --eval 'db.runCommand({ping: 1}).ok' 2>/dev/null | grep -q 1 && break
  sleep 1
done

t0=$(date +%s%N)
"$CTR" exec "$name" mongorestore --quiet --archive=/in/dump --gzip
t1=$(date +%s%N)
got=$("$CTR" exec "$name" mongo --quiet --eval \
  "var d=db.getSiblingDB('nightscout'); print(d.getCollectionNames().sort().map(c => c + ':' + d.getCollection(c).countDocuments({})).join('/'))")

declare -A lo hi have
parse() {
  local -n into=$1
  local pair pairs
  IFS=/ read -ra pairs <<<"$2"
  # shellcheck disable=SC2034  # nameref: assigning to into fills the caller's array
  for pair in "${pairs[@]}"; do into[${pair%%:*}]=${pair##*:}; done
}
parse lo "$min"
parse hi "$max"
parse have "$got"

bad=0
for c in $(printf '%s\n' "${!lo[@]}" | sort); do
  want_lo=${lo[$c]}
  want_hi=${hi[$c]:-$want_lo}
  n=${have[$c]:-}
  if [[ -z $n ]]; then
    echo "MISSING  $c (expected $want_lo..$want_hi)"
    bad=1
  elif ((n < want_lo || n > want_hi)); then
    echo "MISMATCH $c: $n (expected $want_lo..$want_hi)"
    bad=1
  else
    echo "ok       $c: $n"
  fi
done
echo "restore_seconds=$(awk -v ns=$((t1 - t0)) 'BEGIN {printf "%.2f", ns / 1e9}')"
exit "$bad"
