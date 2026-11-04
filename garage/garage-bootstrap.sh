#!/usr/bin/env bash
# Idempotent Garage bootstrap on fedora. Run as nlucas from the dir holding garage.toml + garage.container.
# Safe to re-run: skips anything that already exists.
set -euo pipefail

BUCKETS=(backups)                        # Phase 4 pg_dump target; tfstate lives in Postgres (ADR 0001)
QUOTA=500GiB
CAPACITY=10T                             # layout weight only; quotas are the real limiter
CRED_DIR="$HOME/.config/garage"
QUADLET_DIR="$HOME/.config/containers/systemd"
G=(podman exec -e RUST_LOG=warn garage /garage)

log(){ printf '\e[1;34m==>\e[0m %s\n' "$*"; }
die(){ printf '\e[1;31mERR\e[0m %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
[[ $(id -un) == nlucas ]] || die "run as nlucas (rootless)"
loginctl show-user "$USER" -p Linger | grep -q yes || die "linger not enabled"
if ! systemctl --user -q is-active garage.service 2>/dev/null; then
  ss -ltn | grep -Eq ':(3900|3901|3903)\s' && die "port 3900/3901/3903 already in use"
fi
[[ -f garage.toml && -f garage.container ]] || die "garage.toml / garage.container not in $PWD"

# --- dirs ------------------------------------------------------------------
log "Creating directories"
sudo install -d -o "$USER" -g "$USER" -m 0750 /990/garage /990/garage/meta \
  /data/garage /data/garage/data /data/garage/snapshots
install -d -m 0700 "$CRED_DIR" "$HOME/.local/bin"

# --- secrets (files kept 0600 for Prometheus/Terraform/automation; podman secrets for the container)
for s in rpc-secret admin-token metrics-token; do
  f="$CRED_DIR/$s"
  if [[ ! -s $f ]]; then
    ( umask 077; [[ $s == rpc-secret ]] && openssl rand -hex 32 >"$f" || openssl rand -base64 32 >"$f" )
  fi
  podman secret exists "garage-$s" || podman secret create "garage-$s" "$f" >/dev/null
done

# --- config + quadlet ------------------------------------------------------
log "Installing config and quadlet"
install -m 0640 garage.toml /990/garage/garage.toml
install -d "$QUADLET_DIR"
install -m 0644 garage.container "$QUADLET_DIR/garage.container"
systemctl --user daemon-reload
systemctl --user restart garage.service

log "Waiting for Garage"
for _ in {1..30}; do "${G[@]}" status >/dev/null 2>&1 && break; sleep 2; done
"${G[@]}" status >/dev/null 2>&1 || die "garage not answering; journalctl --user -u garage"

# --- layout ----------------------------------------------------------------
if "${G[@]}" status | grep -q 'NO ROLE ASSIGNED'; then
  log "Assigning layout"
  NODE=$("${G[@]}" node id -q | cut -d@ -f1)
  "${G[@]}" layout assign -z fedora -c "$CAPACITY" "$NODE"
  CUR=$("${G[@]}" layout show | awk 'tolower($0) ~ /current cluster layout version/ {print $NF}')
  "${G[@]}" layout apply --version "$(( ${CUR:-0} + 1 ))"
fi

# --- buckets, keys, grants, quotas -----------------------------------------
for b in "${BUCKETS[@]}"; do
  "${G[@]}" bucket info "$b" >/dev/null 2>&1 || { log "Bucket $b"; "${G[@]}" bucket create "$b"; }
  "${G[@]}" key info "$b" >/dev/null 2>&1 || { log "Key $b"; "${G[@]}" key create "$b" >/dev/null; }
  "${G[@]}" bucket allow --read --write --owner "$b" --key "$b" >/dev/null
  "${G[@]}" bucket set-quotas "$b" --max-size "$QUOTA" >/dev/null

  envf="$CRED_DIR/$b.env"
  if [[ ! -s $envf ]]; then
    info=$("${G[@]}" key info "$b" --show-secret)
    kid=$(awk -F': *' '/Key ID/{print $2; exit}' <<<"$info")
    sec=$(awk -F': *' '/Secret key/{print $2; exit}' <<<"$info")
    [[ -n $kid && -n $sec ]] || die "could not parse key $b"
    ( umask 077; printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$kid" "$sec" >"$envf" )
  fi
done

# --- CLI wrapper -----------------------------------------------------------
printf '#!/bin/sh\nexec podman exec -i -e RUST_LOG=warn garage /garage "$@"\n' >"$HOME/.local/bin/garage"
chmod 0755 "$HOME/.local/bin/garage"

log "Done"
"${G[@]}" status
"${G[@]}" bucket list
echo "Creds: $CRED_DIR/<bucket>.env   Metrics token: $CRED_DIR/metrics-token"
