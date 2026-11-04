#!/usr/bin/env bash
# Syncs NPM's Let's Encrypt *.noellucas.io cert into the rootless postgres container and hot-reloads.
# Idempotent and quiet when nothing changed; run daily by pg-tls-sync.timer. No Postgres restart, ever.
#   - picks the NPM cert by SAN (not by npm-N number), newest expiry wins
#   - refuses expired certs and key/cert mismatches before touching anything
#   - atomic swap, ownership mapped to the container's postgres uid via podman unshare
#   - enables ssl via ALTER SYSTEM on first run, then pg_reload_conf(); verifies what the socket serves
set -euo pipefail

LE_LIVE=${LE_LIVE:-/data/appdata/npm/letsencrypt/live}
SAN=${SAN:-DNS:*.noellucas.io}
CONTAINER=${CONTAINER:-postgres}
HOST_TLS_DIR=${HOST_TLS_DIR:-/990/postgresql/data/tls}     # Volume=/990/postgresql/data:/var/lib/postgresql
CTR_TLS_DIR=/var/lib/postgresql/tls
PG_UID=${PG_UID:-999}                                       # `podman exec postgres id postgres`
VERIFY_HOST=${VERIFY_HOST:-pgsql.noellucas.io:5432}

log(){ printf '%s\n' "$*"; }
die(){ printf 'ERR %s\n' "$*" >&2; exit 1; }
psql_c(){ podman exec "$CONTAINER" psql -X -qtA -U postgres -c "$1"; }
fp(){ openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }

# --- pick source cert by SAN, newest notAfter ---------------------------------------------------
best='' best_end=0
for d in "$LE_LIVE"/*/; do
  c="$d/fullchain.pem"; [[ -r $c ]] || continue
  openssl x509 -in "$c" -noout -ext subjectAltName 2>/dev/null | grep -qF "$SAN" || continue
  end=$(date -d "$(openssl x509 -in "$c" -noout -enddate | cut -d= -f2)" +%s)
  (( end > best_end )) && { best=${d%/}; best_end=$end; }
done
[[ -n $best ]] || die "no cert with $SAN under $LE_LIVE"
SRC_CRT="$best/fullchain.pem" SRC_KEY="$best/privkey.pem"

# --- gate: valid now, key matches -----------------------------------------------------------------
openssl x509 -in "$SRC_CRT" -noout -checkend 0 >/dev/null || die "source cert $SRC_CRT is expired"
[[ "$(openssl x509 -in "$SRC_CRT" -noout -pubkey | sha256sum)" == \
   "$(openssl pkey -in "$SRC_KEY" -pubout | sha256sum)" ]] || die "key/cert mismatch in $best"

# --- install only if changed ----------------------------------------------------------------------
changed=0
# The data volume is owned by the container's postgres uid, so all reads/writes there go through
# podman unshare (nlucas == root inside the user namespace).
if ! podman unshare cmp -s "$SRC_CRT" "$HOST_TLS_DIR/server.crt" 2>/dev/null; then
  # shellcheck disable=SC2016
  podman unshare sh -euc '
    d=$1 uid=$4
    install -d -m 0755 -o "$uid" -g "$uid" "$d"
    install -m 0644 -o "$uid" -g "$uid" "$2" "$d/.server.crt.new"
    install -m 0600 -o "$uid" -g "$uid" "$3" "$d/.server.key.new"   # postgres refuses a key it does not own
    mv -f "$d/.server.crt.new" "$d/server.crt"
    mv -f "$d/.server.key.new" "$d/server.key"
  ' _ "$HOST_TLS_DIR" "$SRC_CRT" "$SRC_KEY" "$PG_UID"
  changed=1
  log "installed $(fp "$SRC_CRT") from $best, expires $(date -d "@$best_end" -I)"
fi

# --- enable ssl once (persists in postgresql.auto.conf), reload on any change ----------------------
if [[ $(psql_c "show ssl") != on || $(psql_c "show ssl_cert_file") != "$CTR_TLS_DIR/server.crt" ]]; then
  psql_c "ALTER SYSTEM SET ssl_cert_file = '$CTR_TLS_DIR/server.crt'"
  psql_c "ALTER SYSTEM SET ssl_key_file  = '$CTR_TLS_DIR/server.key'"
  psql_c "ALTER SYSTEM SET ssl_min_protocol_version = 'TLSv1.2'"
  psql_c "ALTER SYSTEM SET ssl = on"
  changed=1
fi
(( changed )) || exit 0
[[ $(psql_c "select pg_reload_conf()") == t ]] || die "pg_reload_conf() failed"
sleep 1
[[ $(psql_c "show ssl") == on ]] || die "ssl still off after reload; check: podman logs $CONTAINER | tail"

# --- verify what clients actually get ---------------------------------------------------------------
served=$(openssl s_client -starttls postgres -connect "$VERIFY_HOST" -servername "${VERIFY_HOST%:*}" \
           -verify_return_error </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)
[[ $served == "$(fp "$SRC_CRT")" ]] || die "socket serves ${served:-nothing}, expected $(fp "$SRC_CRT")"
log "verified: $VERIFY_HOST serves the new cert with a valid chain"
