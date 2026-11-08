#!/usr/bin/env bash
# Tests for deploy.sh, health.sh and check-images.sh against a fake kubectl and curl, run under the
# same shell flags as Actions (bash -e -o pipefail). Every failure path has its own case.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fails=0

make_fakes(){ # $1 = dir
  mkdir -p "$1/bin"
  cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# Fake kubectl. State in $FAKE: gen_<workload>, undone_<workload>, curlmode, calls.
echo "kubectl $*" >> "$FAKE/calls"
[ "${1:-}" = -n ] && shift 2
f(){ echo "$FAKE/$1_${2//\//_}"; }
case "$1" in
  get)
    case "$2" in
      secret) [ "${NO_SECRET:-}" = 1 ] && exit 1; printf '%s' "$(printf 'test-secret-123' | base64)";;
      pods|events) echo "fake $2";;
      *) [ -f "$(f gen "$2")" ] && cat "$(f gen "$2")" || { echo "NotFound" >&2; exit 1; };;
    esac;;
  apply)
    for w in ${CHANGED//_/ }; do g=$(f gen "$w"); echo $(( $(cat "$g" 2>/dev/null || echo 0) + 1 )) > "$g"; done
    echo "applied";;
  rollout)
    case "$2" in
      status)
        if [[ " ${FAIL_ROLLOUT:-} " == *" $3 "* ]] && [ ! -f "$(f undone "$3")" ]; then
          echo "error: $3 exceeded its progress deadline" >&2; exit 1; fi
        echo "$3 rolled out";;
      undo)
        touch "$(f undone "$3")"; g=$(f gen "$3"); echo $(( $(cat "$g") + 1 )) > "$g"
        echo "$3" >> "$FAKE/undo.log"
        [ -n "${AFTER_UNDO:-}" ] && echo "$AFTER_UNDO" > "$FAKE/curlmode"
        echo "$3 rolled back";;
    esac;;
esac
EOF
  cat > "$1/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: requires the api-secret header (SHA-1 of the fake secret) via -H @file, and refuses
# to run if the hash appears on its own command line.
want=$(printf 'test-secret-123' | sha1sum | cut -d' ' -f1)
for a in "$@"; do [[ $a == *"$want"* ]] && { echo "secret hash on the command line" >&2; exit 99; }; done
hdrok=no; prev=""
for a in "$@"; do
  if [ "$prev" = -H ] && [[ $a == @* ]] && grep -qx "api-secret: $want" "${a#@}"; then hdrok=yes; fi
  prev=$a
done
url=${!#}; mode=$(cat "$FAKE/curlmode")
if [ "$hdrok" != yes ] || [ "$mode" = 401 ]; then echo "curl: (22) The requested URL returned error: 401" >&2; exit 22; fi
now=$(date +%s%3N)
case "$url" in
  */status.json) echo '{"status":"ok"}';;
  */entries/sgv.json*)
    case "$mode" in
      fresh) echo "[{\"date\": $(( now - 2*60000 )), \"sgv\": 110}]";;
      stale) echo "[{\"date\": $(( now - 30*60000 )), \"sgv\": 110}]";;
      empty) echo "[]";;
      junk)  echo "<html>proxy error</html>";;
    esac;;
esac
EOF
  chmod +x "$1/bin/kubectl" "$1/bin/curl"
}

# case NAME SCRIPT WANT_EXIT WANT_UNDO "VAR=val ..."   (initial generations in GENS="w=n ...")
case_(){
  local name=$1 script=$2 want=$3 want_undo=$4 vars=$5
  FAKE=$(mktemp -d); export FAKE; make_fakes "$FAKE"
  echo "${MODE:-fresh}" > "$FAKE/curlmode"
  for kv in ${GENS:-}; do echo "${kv#*=}" > "$FAKE/gen_${kv%%=*}"; done
  set +e
  out=$(env PATH="$FAKE/bin:$PATH" HEALTH_TIMEOUT=0 HEALTH_INTERVAL=0 REPORT="$FAKE/report.md" \
        DIR=k8s/nightscout $vars bash -e -o pipefail "$here/$script" 2>&1)
  rc=$?
  set -e
  undo=""; [ -f "$FAKE/undo.log" ] && undo=$(tr "\n" " " < "$FAKE/undo.log" | sed "s/ $//")
  if [ "$rc" = "$want" ] && [ "$undo" = "$want_undo" ]; then
    echo "PASS $name (exit $rc${undo:+, undo: $undo})"
  else
    echo "FAIL $name: exit $rc want $want; undo '$undo' want '$want_undo'"; echo "$out" | sed 's/^/    /'; fails=1
  fi
  rm -rf "$FAKE"
}

ALL="statefulset_mongo=1 deployment_nightscout=1 deployment_tconnectsync=1"

echo "--- health.sh"
GENS="" MODE=fresh case_ "fresh reading -> healthy"          health.sh 0 "" ""
GENS="" MODE=stale case_ "30 min old reading -> unhealthy"   health.sh 1 "" ""
GENS="" MODE=empty case_ "no readings -> unhealthy"          health.sh 1 "" ""
GENS="" MODE=junk  case_ "non-JSON answer -> unhealthy"      health.sh 1 "" ""
GENS="" MODE=401   case_ "401 -> unhealthy"                  health.sh 1 "" ""
GENS="" MODE=fresh case_ "secret unreadable -> unhealthy"    health.sh 1 "" "NO_SECRET=1"

echo "--- deploy.sh"
GENS=$ALL MODE=fresh case_ "good release"                          deploy.sh 0 "" \
  "CHANGED=deployment/nightscout"
GENS=$ALL MODE=fresh case_ "bad image tag -> undo nightscout only"  deploy.sh 1 "deployment/nightscout" \
  "CHANGED=deployment/nightscout FAIL_ROLLOUT=deployment/nightscout"
GENS=$ALL MODE=stale case_ "rolls out but stale -> undo, recovers"  deploy.sh 1 "deployment/nightscout" \
  "CHANGED=deployment/nightscout AFTER_UNDO=fresh"
GENS=$ALL MODE=stale case_ "stale before and after -> exit 2"       deploy.sh 2 "deployment/nightscout" \
  "CHANGED=deployment/nightscout"
GENS=$ALL MODE=fresh case_ "two workloads changed -> undo both"     deploy.sh 1 "deployment/nightscout deployment/tconnectsync" \
  "CHANGED=deployment/nightscout_deployment/tconnectsync FAIL_ROLLOUT=deployment/tconnectsync"
GENS=""   MODE=fresh case_ "first deploy fails -> nothing to undo"  deploy.sh 1 "" \
  "CHANGED=statefulset/mongo_deployment/nightscout_deployment/tconnectsync FAIL_ROLLOUT=deployment/nightscout"
GENS=$ALL MODE=stale case_ "ingress-only change, stale -> no undo"  deploy.sh 1 "" \
  "CHANGED="
GENS=$ALL MODE=fresh case_ "new exporter fails -> nothing to undo"  deploy.sh 1 "" \
  "CHANGED=deployment/ns-exporter FAIL_ROLLOUT=deployment/ns-exporter"
GENS="$ALL deployment_ns-exporter=1" MODE=fresh case_ "exporter change fails -> undo exporter only" deploy.sh 1 "deployment/ns-exporter" \
  "CHANGED=deployment/ns-exporter FAIL_ROLLOUT=deployment/ns-exporter"

echo "--- check-images.sh"
img(){ printf '      - image: %s\n' "$@"; }
d=$(printf 'a%.0s' {1..64})
for t in "ok|0|docker.io/x/y:1.2.3@sha256:$d" "tag only|1|docker.io/x/y:1.2.3" "digest only|1|docker.io/x/y@sha256:$d" \
         "latest|1|docker.io/x/y:latest@sha256:$d" "short digest|1|docker.io/x/y:1@sha256:abc"; do
  IFS='|' read -r n want i <<< "$t"
  set +e; img "$i" | bash -e -o pipefail "$here/check-images.sh" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "$want" ] && echo "PASS images: $n (exit $rc)" || { echo "FAIL images: $n exit $rc want $want"; fails=1; }
done
set +e; printf 'kind: ConfigMap\n' | bash -e -o pipefail "$here/check-images.sh" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] && echo "PASS images: none found (exit 1)" || { echo "FAIL images: none found exit $rc"; fails=1; }

exit "$fails"
