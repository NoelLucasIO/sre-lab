#!/usr/bin/env bash
# Post-deploy health check for the Nightscout copy: the API answers (authenticated) and the newest
# CGM reading is under MAX_AGE_MIN minutes old. Polls until HEALTH_TIMEOUT seconds have passed.
# Exit 0 healthy, 1 unhealthy.
set -euo pipefail
NS=${NS:-nightscout}
URL=${NS_URL:-http://ns-k3s.noellucas.io}
# Reach Traefik directly, so the check does not depend on a DNS record.
RESOLVE=${NS_RESOLVE:-ns-k3s.noellucas.io:80:192.168.2.40}
MAX_AGE_MIN=${MAX_AGE_MIN:-10}
DEADLINE=${HEALTH_TIMEOUT:-600}
INTERVAL=${HEALTH_INTERVAL:-20}

# Nightscout accepts the SHA-1 of API_SECRET in an `api-secret` header. Keep it in a mode-600
# header file, not on curl's command line (visible in `ps`).
hdr=$(mktemp); trap 'rm -f "$hdr"' EXIT; chmod 600 "$hdr"
secret_b64=$(kubectl -n "$NS" get secret nightscout-secrets -o jsonpath='{.data.API_SECRET}') \
  && [ -n "$secret_b64" ] || { echo "unhealthy: cannot read API_SECRET from nightscout-secrets"; exit 1; }
printf 'api-secret: %s\n' "$(printf '%s' "$secret_b64" | base64 -d | sha1sum | cut -d' ' -f1)" > "$hdr"
unset secret_b64

get(){ curl -fsS --max-time 10 --resolve "$RESOLVE" -H "@$hdr" "$URL$1"; }

end=$(( $(date +%s) + DEADLINE )); last="no attempt"
while :; do
  if ! out=$(get /api/v1/status.json 2>&1); then
    last="status endpoint failed: ${out:0:160}"
  elif ! out=$(get '/api/v1/entries/sgv.json?count=1' 2>&1); then
    last="entries query failed: ${out:0:160}"
  else
    newest=$(printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["date"] if d else "")' 2>/dev/null) || newest=""
    if [ -z "$newest" ]; then
      last="no CGM readings yet"
    else
      age=$(( ($(date +%s%3N) - newest) / 60000 ))
      if [ "$age" -lt "$MAX_AGE_MIN" ]; then
        echo "healthy: API answering, newest reading ${age} min old (limit ${MAX_AGE_MIN})"; exit 0
      fi
      last="newest reading ${age} min old (limit ${MAX_AGE_MIN})"
    fi
  fi
  [ "$(date +%s)" -lt "$end" ] || break
  echo "waiting: $last"; sleep "$INTERVAL"
done
echo "unhealthy after ${DEADLINE}s: $last"; exit 1
