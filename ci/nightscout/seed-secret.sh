#!/usr/bin/env bash
# Create or refresh the nightscout-secrets Secret for the k3s copy. Run once on fedora as nlucas,
# after the k3s workflow has created the namespace:   ~/sre-lab/ci/nightscout/seed-secret.sh
#
# The Dexcom Share and Tandem logins are read from the live pod's quadlet files and Podman
# secrets. Values travel fedora -> k3s-server-1 only over SSH stdin: nothing is printed, written
# to disk, put on a command line, or committed. The copy gets its OWN API secret, generated on
# the first run and kept on later runs.
set -euo pipefail
Q=$HOME/.config/containers/systemd
SSH=(ssh -i "$HOME/.ssh/id_ed25519_automation" -o BatchMode=yes -o StrictHostKeyChecking=yes
     -o UserKnownHostsFile="$HOME/sre-lab/ci/runner/known_hosts" k3s-server-1.noellucas.io)
K="sudo k3s kubectl -n nightscout"

"${SSH[@]}" "$K get serviceaccount deployer >/dev/null" \
  || { echo "namespace nightscout not ready: run the k3s workflow (cluster-access) first" >&2; exit 1; }

secret(){ podman secret inspect --showsecret --format '{{.SecretData}}' "$1"; }
b64(){ printf '%s' "$1" | base64 -w0; }

api=$("${SSH[@]}" "$K get secret nightscout-secrets -o jsonpath='{.data.API_SECRET}' 2>/dev/null" | base64 -d 2>/dev/null || true)
fresh=no
if [ -z "$api" ]; then api=$(openssl rand -hex 24); fresh=yes; fi

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
unset api bridge_pass tandem_pass
echo "nightscout-secrets applied (API secret for the copy: $([ "$fresh" = yes ] && echo newly generated || echo kept))."
echo "If the copy is already running, pick up changes with: kubectl -n nightscout rollout restart deploy"
