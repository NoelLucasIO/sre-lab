#!/usr/bin/env bash
# DR restore of the k3s copy's Nightscout database from the offsite copy (ADR 0010, DR drill).
# Run on fedora as nlucas, from the repo, with an AWS session that can read the backup prefix:
#   aws sso login --profile sre-lab-admin --use-device-code
#   AWS_PROFILE=sre-lab-admin backup/restore-k3s.sh
#
#   1. newest S3 dump, age (MAX_AGE_HOURS, default 26) and SHA-256 checked (offsite.sh s3-get)
#   2. proven in a throwaway Mongo first (restore-check.sh): if that fails, k3s is never touched
#   3. nightscout and tconnectsync scaled to 0, so nothing writes during the restore
#   4. mongorestore --drop into mongo-0, over the admin SSH route (the namespace-scoped deployer
#      cannot exec into pods)
#   5. every collection's count checked on k3s, then both writers back to their previous replicas
#      (they are also scaled back if any step after 3 fails)
# Each phase prints a UTC timestamp; with DRILL_LOG set, drill/mark records them too.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
export BUCKET=${BUCKET:-sre-lab-backups-420802201910}
SSH=(ssh -i "$HOME/.ssh/id_ed25519_automation" -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$REPO/ci/runner/known_hosts" "${K3S_SERVER:-k3s-server-1.noellucas.io}")
K="sudo k3s kubectl -n nightscout"
WRITERS=(deployment/nightscout deployment/tconnectsync)
COUNT_JS='var d=db.getSiblingDB("nightscout"); print(d.getCollectionNames().sort().map(c => c + ":" + d.getCollection(c).countDocuments({})).join("/"))'

step() {
  printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"
  if [[ -n ${DRILL_LOG:-} ]]; then "$REPO/drill/mark" "restore: $*" >/dev/null || true; fi
}

work=$(mktemp -d)
declare -A replicas
scaled=no
cleanup() {
  if [[ $scaled == yes ]]; then
    for w in "${WRITERS[@]}"; do
      "${SSH[@]}" "$K scale $w --replicas=${replicas[$w]}" >/dev/null ||
        echo "WARNING: could not scale $w back to ${replicas[$w]}: do it by hand" >&2
    done
  fi
  rm -rf "$work"
}
trap cleanup EXIT

step "1/5 newest dump from S3"
"$HERE/offsite.sh" s3-get "$work"
key=$(cat "$work/key")
min=$(cat "$work/counts-min")
max=$(cat "$work/counts-max")

step "2/5 prove it in a throwaway Mongo"
"$HERE/restore-check.sh" "$work/dump" "$min" "$max"

step "3/5 stop the writers"
"${SSH[@]}" "$K rollout status statefulset/mongo --timeout=300s" >/dev/null
for w in "${WRITERS[@]}"; do replicas[$w]=$("${SSH[@]}" "$K get $w -o jsonpath={.spec.replicas}"); done
scaled=yes
for w in "${WRITERS[@]}"; do "${SSH[@]}" "$K scale $w --replicas=0" >/dev/null; done
"${SSH[@]}" "$K wait --for=delete pod -l 'app in (nightscout,tconnectsync)' --timeout=120s" >/dev/null 2>&1 || true

step "4/5 mongorestore --drop into mongo-0: $key"
"${SSH[@]}" "$K exec -i mongo-0 -- mongorestore --quiet --archive --gzip --drop --nsInclude 'nightscout.*'" <"$work/dump"

step "5/5 verify on k3s, then restart the writers"
got=$("${SSH[@]}" "$K exec mongo-0 -- mongosh --quiet --eval '$COUNT_JS'")
python3 - "$min" "$max" "$got" <<'EOF'
import sys
parse = lambda s: dict(p.rsplit(":", 1) for p in s.strip().split("/") if p)
lo, hi, got = (parse(a) for a in sys.argv[1:4])
bad = False
for c in sorted(lo):
    a, b, n = int(lo[c]), int(hi.get(c, lo[c])), got.get(c)
    ok = n is not None and a <= int(n) <= b
    bad |= not ok
    print(f"{'ok      ' if ok else 'MISMATCH'} {c}: {n} (expected {a}..{b})")
sys.exit(1 if bad else 0)
EOF
for w in "${WRITERS[@]}"; do "${SSH[@]}" "$K scale $w --replicas=${replicas[$w]}" >/dev/null; done
scaled=no
for w in "${WRITERS[@]}"; do "${SSH[@]}" "$K rollout status $w --timeout=300s" >/dev/null; done
step "done: $key restored and verified; writers running"
