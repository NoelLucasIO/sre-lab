#!/usr/bin/env bash
# Deploy k8s/nightscout, verify it, and roll back automatically if it is not healthy.
#   1. record each workload's generation      4. health check (ci/nightscout/health.sh)
#   2. kubectl apply -k                       5. on any failure: `rollout undo` every workload this
#   3. rollout status for every workload         apply changed, wait, and health-check the result
# Exit 0: deployed and healthy.  1: failed, rolled back (or nothing to roll back), service healthy
# or unknown.  2: failed and still unhealthy after the rollback.  Writes markdown to $REPORT.
set -euo pipefail
NS=${NS:-nightscout}
DIR=${DIR:-k8s/nightscout}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-300s}
REPORT=${REPORT:-/dev/null}
HERE=$(cd "$(dirname "$0")" && pwd)
WORKLOADS=(statefulset/mongo deployment/nightscout deployment/tconnectsync)

k(){ kubectl -n "$NS" "$@"; }
gen(){ k get "$1" -o jsonpath='{.metadata.generation}' 2>/dev/null || true; }
say(){ echo "$*"; echo "$*" >> "$REPORT"; }
diagnose(){
  { echo; echo '<details><summary>pods and recent events</summary>'; echo; echo '```'
    k get pods -o wide 2>&1 || true
    k get events --sort-by=.lastTimestamp 2>&1 | tail -15 || true
    echo '```'; echo '</details>'; echo; } >> "$REPORT"   # blank line: markdown after </details> needs it
}

declare -A before
for w in "${WORKLOADS[@]}"; do before[$w]=$(gen "$w"); done

say "### Nightscout deploy of \`${GITHUB_SHA:-local}\`"
k apply -k "$DIR" || { say "- **FAILED:** the API rejected \`kubectl apply\` (see the job log; objects applied before the error stay applied)"; diagnose; exit 1; }

failed=""
for w in "${WORKLOADS[@]}"; do
  k rollout status "$w" --timeout="$ROLLOUT_TIMEOUT" || failed="$failed $w"
done

if [ -n "$failed" ]; then
  reason="rollout did not complete:$failed"
elif "$HERE/health.sh"; then
  say "- deployed and healthy"; exit 0
else
  reason="health check failed after a complete rollout"
fi
say "- **FAILED:** $reason"
diagnose

undone=""
for w in "${WORKLOADS[@]}"; do
  if [ -n "${before[$w]}" ] && [ "$(gen "$w")" != "${before[$w]}" ]; then
    k rollout undo "$w" && undone="$undone $w"
  fi
done
if [ -z "$undone" ]; then
  say "- nothing to roll back (first deploy, or this change touched no workload)"; exit 1
fi
say "- rolled back:$undone"

for w in $undone; do
  k rollout status "$w" --timeout="$ROLLOUT_TIMEOUT" || { say "- **rollback of $w did not complete**"; exit 2; }
done
if "$HERE/health.sh"; then
  say "- previous version restored and healthy; \`main\` still holds the failed change: revert it"
  exit 1
fi
say "- **previous version is also unhealthy**: look beyond this change (upstream data, cluster)"
exit 2
