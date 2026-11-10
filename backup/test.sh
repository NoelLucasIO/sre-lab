#!/usr/bin/env bash
# Self-test for backup/ (the `backup scripts` job on every PR): shellcheck, then a real
# mongodump -> restore-check round trip on a synthetic database, plus the cases that must fail
# (a count out of range, a missing collection). Usage: [CTR=docker|podman] backup/test.sh
set -euo pipefail
cd "$(dirname "$0")"

shellcheck -x ./*.sh ../garage/backup-keys.sh ../drill/mark

# drill/mark: T0 is the zero, --report gives elapsed time per mark.
log=$(mktemp)
DRILL_LOG=$log ../drill/mark "prep" >/dev/null
DRILL_LOG=$log ../drill/mark "T0 destroy complete" >/dev/null
DRILL_LOG=$log ../drill/mark "rebuilt" | grep -q '(T0 +0:0[0-9])' || { echo "FAIL: drill/mark elapsed"; exit 1; }
DRILL_LOG=$log ../drill/mark --report | grep -qE '^\| [0-9:]{8} \| 0:0[0-9] \| 0:0[0-9] \| rebuilt \|$' || { echo "FAIL: drill/mark --report"; exit 1; }
rm -f "$log"
echo "drill/mark: ok"

MONGO_IMAGE=${MONGO_IMAGE:-docker.io/library/mongo:4.4@sha256:7250955b2354cc6ad3548b428628e441e34625caa39dd64906e85adf369e1942}
CTR=${CTR:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}
export CTR MONGO_IMAGE
src=nsbackup-src-$$
tmp=$(mktemp -d)
trap '"$CTR" rm -f "$src" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

"$CTR" run -d --rm --name "$src" --network none "$MONGO_IMAGE" >/dev/null
for _ in $(seq 60); do
  "$CTR" exec "$src" mongo --quiet --eval 'db.runCommand({ping: 1}).ok' 2>/dev/null | grep -q 1 && break
  sleep 1
done

# Shaped like Nightscout: readings, treatments, an empty collection, a profile.
"$CTR" exec "$src" mongo --quiet --eval '
  var d = db.getSiblingDB("nightscout");
  var e = []; for (var i = 0; i < 500; i++) e.push({sgv: 100 + i % 50, date: 1794268800000 + i * 300000, type: "sgv"});
  d.entries.insertMany(e);
  d.treatments.insertMany([{eventType: "Meal Bolus", insulin: 2.5}, {eventType: "Temp Basal", rate: 0.8}]);
  d.createCollection("devicestatus");
  d.profile.insertOne({defaultProfile: "Default"});' >/dev/null
counts=$("$CTR" exec "$src" mongo --quiet --eval \
  "var d=db.getSiblingDB('nightscout'); print(d.getCollectionNames().sort().map(c => c + ':' + d.getCollection(c).countDocuments({})).join('/'))")
"$CTR" exec "$src" mongodump --quiet --db nightscout --archive --gzip >"$tmp/dump"
echo "synthetic dump: $(stat -c %s "$tmp/dump") bytes, counts $counts"

echo "--- must pass"
./restore-check.sh "$tmp/dump" "$counts" "$counts"

echo "--- must fail: a count out of range"
if ./restore-check.sh "$tmp/dump" "${counts/entries:500/entries:501}" "${counts/entries:500/entries:600}"; then
  echo "FAIL: an out-of-range count passed"; exit 1
fi
echo "--- must fail: a collection the dump does not have"
if ./restore-check.sh "$tmp/dump" "$counts/food:1" "$counts/food:1"; then
  echo "FAIL: a missing collection passed"; exit 1
fi
echo "backup/test.sh: all checks passed"
