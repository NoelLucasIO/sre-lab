#!/usr/bin/env bash
# Create or refresh the nightscout-secrets Secret for the k3s copy. Run on fedora as nlucas,
# after the k3s workflow has created the namespace:   ~/sre-lab/ci/nightscout/seed-secret.sh
#
# The Dexcom Share and Tandem logins are read from the live pod's quadlet files and Podman
# secrets. Values travel fedora -> k3s-server-1 only over SSH stdin: nothing is printed, written
# to disk, put on a command line, or committed.
#
# The copy has its OWN API secret. Its source of truth is the Podman secret ns-k3s-api-secret on
# fedora, so it survives a rebuild of the cluster (DR drill 2026-11-11, finding 2: a fresh cluster
# got a new secret and the probe, still sending the old one's hash, failed with 401).
#   Podman secret present         -> used as is (and written to the cluster if the cluster differs)
#   absent, cluster has a secret  -> adopted into Podman
#   absent everywhere             -> generated once
# The Blackbox probe header (ns-k3s-api-hash, sha1 of the API secret) is then checked and, if it
# does not match, recreated and Blackbox restarted.
set -euo pipefail
Q=$HOME/.config/containers/systemd
API_PS=ns-k3s-api-secret
HASH_PS=ns-k3s-api-hash
SSH=(ssh -i "$HOME/.ssh/id_ed25519_automation" -o BatchMode=yes -o StrictHostKeyChecking=yes
     -o UserKnownHostsFile="$HOME/sre-lab/ci/runner/known_hosts" k3s-server-1.noellucas.io)
K="sudo k3s kubectl -n nightscout"

"${SSH[@]}" "$K get serviceaccount deployer >/dev/null" \
  || { echo "namespace nightscout not ready: run the k3s workflow (cluster-access) first" >&2; exit 1; }

secret(){ podman secret inspect --showsecret --format '{{.SecretData}}' "$1"; }
has_secret(){ podman secret exists "$1"; }
b64(){ printf '%s' "$1" | base64 -w0; }
sha1(){ printf '%s' "$1" | sha1sum | cut -d' ' -f1; }

cluster_api=$("${SSH[@]}" "$K get secret nightscout-secrets -o jsonpath='{.data.API_SECRET}' 2>/dev/null" | base64 -d 2>/dev/null || true)
if has_secret "$API_PS"; then
  api=$(secret "$API_PS")
  if [ -z "$cluster_api" ]; then source="from $API_PS (cluster had none)"
  elif [ "$cluster_api" = "$api" ]; then source="from $API_PS (cluster already matched)"
  else source="from $API_PS (cluster had a different one: replaced)"; fi
elif [ -n "$cluster_api" ]; then
  api=$cluster_api
  printf '%s' "$api" | podman secret create "$API_PS" - >/dev/null
  source="adopted from the cluster into $API_PS"
else
  api=$(openssl rand -hex 24)
  printf '%s' "$api" | podman secret create "$API_PS" - >/dev/null
  source="newly generated and stored in $API_PS"
fi
unset cluster_api

bridge_user=$(sed -n 's/^BRIDGE_USER_NAME=//p' "$Q/nightscout.env" | head -1)
tconnect_email=$(sed -n 's/^Environment=TCONNECT_EMAIL=//p' "$Q/nightscout-tconnectsync.container" | head -1)
bridge_pass=$(secret ns-bridge-pass)
tandem_pass=$(secret ns-tandem-pass)
for v in api bridge_user tconnect_email bridge_pass tandem_pass; do
  [ -n "${!v}" ] || { echo "missing value: $v" >&2; exit 1; }
done

cat <<EOF | "${SSH[@]}" "$K apply -f -"
apiVersion: v1
kind: Secret
metadata:
  name: nightscout-secrets
  namespace: nightscout
type: Opaque
data:
  API_SECRET: $(b64 "$api")
  BRIDGE_USER_NAME: $(b64 "$bridge_user")
  BRIDGE_PASSWORD: $(b64 "$bridge_pass")
  TCONNECT_EMAIL: $(b64 "$tconnect_email")
  TCONNECT_PASSWORD: $(b64 "$tandem_pass")
EOF
unset bridge_pass tandem_pass
echo "nightscout-secrets applied (copy API secret: $source)."

# The probe authenticates with sha1(API secret); keep it in step.
want=$(sha1 "$api"); unset api
have=$(has_secret "$HASH_PS" && secret "$HASH_PS" || true)
if [ "$have" = "$want" ]; then
  echo "probe header $HASH_PS: already matches."
else
  has_secret "$HASH_PS" && podman secret rm "$HASH_PS" >/dev/null
  printf '%s' "$want" | podman secret create "$HASH_PS" - >/dev/null
  systemctl --user restart blackbox
  echo "probe header $HASH_PS: recreated, blackbox restarted."
fi
unset want have
echo "If the copy is already running, pick up changes with: kubectl -n nightscout rollout restart deploy"
