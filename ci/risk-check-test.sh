#!/usr/bin/env bash
# Fixture tests for ci/risk-check.py: each case asserts the exit code.
set -euo pipefail
cd "$(dirname "$0")"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
rc() { printf '{"address":"%s","change":{"actions":%s,"before":%s,"after":%s}}' "$1" "$2" "$3" "$4"; }
plan() { printf '{"resource_changes":[%s]}' "$(IFS=,; echo "$*")" > "$t/$P.json"; }

P=noop;     plan "$(rc a '["no-op"]' '{}' '{}')"
P=update;   plan "$(rc a '["update"]' '{"x":1}' '{"x":2}')"
P=replace1; plan "$(rc vm '["delete","create"]' '{}' '{}')" "$(rc iso '["delete","create"]' '{}' '{}')"
P=replace3; plan "$(rc a '["delete","create"]' '{}' '{}')" "$(rc b '["delete"]' '{}' '{}')" "$(rc c '["create","delete"]' '{}' '{}')"
P=crit;     plan "$(rc db '["update"]' '{"tags":"{\"critical\":\"true\"}"}' '{"tags":"{\"critical\":\"true\"}"}')"
P=critno;   plan "$(rc db '["update"]' '{"tags":{"critical":"false"}}' '{"tags":{"critical":"false"}}')"

fail=0
check() { # name expected_exit args...
  local n=$1 want=$2; shift 2
  if python3 ./risk-check.py "$@" >/dev/null; then got=0; else got=$?; fi
  if [ "$got" = "$want" ]; then echo "PASS $n"; else echo "FAIL $n (want $want, got $got)"; fail=1; fi
}
check no-op            0 "r=$t/noop.json"
check update           0 "r=$t/update.json"
check two-replaced     0 --max-destroy 2 "r=$t/replace1.json"
check three-replaced   1 --max-destroy 2 "r=$t/replace3.json"
check summed-roots     1 --max-destroy 2 "a=$t/replace1.json" "b=$t/replace1.json"
check override         0 --max-destroy 2 --override "r=$t/replace3.json"
check report-only      0 --max-destroy 2 --report-only "r=$t/replace3.json"
check critical-jsonstr 1 "r=$t/crit.json"
check critical-false   0 "r=$t/critno.json"
exit $fail
