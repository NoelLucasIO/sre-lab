#!/usr/bin/env bash
# Installs the GitHub Actions runner on fedora as a locked-down system user.
#   sudo ~/sre-lab/ci/runner/install.sh        (have the repo's runner token ready; it is read without echo)
# Idempotent: re-running updates the unit and credentials and re-registers only if needed.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

REPO_URL=https://github.com/NoelLucasIO/sre-lab
U=gh-runner H=/var/lib/gh-runner D=/var/lib/gh-runner/actions-runner
SRC_USER=${SUDO_USER:?run via sudo from your own account}
SRC_CFG="$(getent passwd "$SRC_USER" | cut -d: -f6)/.config/terraform"
HERE=$(cd "$(dirname "$0")" && pwd)
log(){ printf '\e[1;34m==>\e[0m %s\n' "$*"; }
die(){ printf '\e[1;31mERR\e[0m %s\n' "$*" >&2; exit 1; }

log "System user $U (no login shell, no sudo; libvirt only)"
id "$U" &>/dev/null || useradd --system --create-home --home-dir "$H" --shell /usr/sbin/nologin \
  --comment "GitHub Actions runner (sre-lab)" "$U"
usermod -aG libvirt "$U"
id -nG "$U" | grep -qw wheel && die "$U must not be in wheel"

log "Least-privilege credentials (never .pgpass or nlucas's SSH keys)"
install -d -o "$U" -g "$U" -m 0700 "$H/.config" "$H/.config/terraform" "$H/.terraform.d" "$H/.terraform.d/plugin-cache"
for f in pg.env grafana.env technitium.env; do
  [[ -s $SRC_CFG/$f ]] || die "missing $SRC_CFG/$f"
  install -o "$U" -g "$U" -m 0600 "$SRC_CFG/$f" "$H/.config/terraform/$f"
done

log "Runner SSH identity (its own key for Ansible; VM host keys pinned, no trust-on-first-use)"
install -d -o "$U" -g "$U" -m 0700 "$H/.ssh"
[[ -f $H/.ssh/id_ed25519 ]] || sudo -u "$U" ssh-keygen -q -t ed25519 -N "" -C "$U@$(hostname -f)" -f "$H/.ssh/id_ed25519"
[[ "$(cut -d' ' -f1,2 "$H/.ssh/id_ed25519.pub")" == "$(cut -d' ' -f1,2 "$HERE/../../keys/gh-runner.pub")" ]] \
  || die "runner key does not match keys/gh-runner.pub; commit the new public key first"
# The k3s workflow re-installs this from the repo on every converge (ADR 0011).
install -o "$U" -g "$U" -m 0644 "$HERE/known_hosts" "$H/.ssh/known_hosts"
printf 'Host k3s-*\n  User nlucas\n  IdentityFile ~/.ssh/id_ed25519\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n' \
  | install -o "$U" -g "$U" -m 0600 /dev/stdin "$H/.ssh/config"

if [[ ! -x $D/run.sh ]]; then
  log "Download actions/runner (SHA-256 verified)"
  read -r VER URL SHA < <(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | python3 -c '
import sys, json, re
r = json.load(sys.stdin); v = r["tag_name"].lstrip("v"); name = f"actions-runner-linux-x64-{v}.tar.gz"
a = next(x for x in r["assets"] if x["name"] == name)
sha = (a.get("digest") or "").removeprefix("sha256:")
if not sha:
    m = re.search(r"BEGIN SHA linux-x64 -->([0-9a-f]{64})", r.get("body") or ""); sha = m.group(1) if m else ""
print(v, a["browser_download_url"], sha)')
  [[ ${#SHA} -eq 64 ]] || die "no published checksum for runner $VER; refusing to install"
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  curl -fsSLo "$T/r.tgz" "$URL"
  echo "$SHA  $T/r.tgz" | sha256sum -c --quiet || die "checksum mismatch"
  install -d -o "$U" -g "$U" -m 0750 "$D"
  tar -xzf "$T/r.tgz" -C "$D"; chown -R "$U:$U" "$D"
  "$D/bin/installdependencies.sh" >/dev/null
  log "runner $VER installed"
fi

if [[ ! -f $D/.runner ]]; then
  read -rsp "Runner registration token (Settings > Actions > Runners > New): " TOKEN; echo
  [[ -n $TOKEN ]] || die "empty token"
  sudo -u "$U" HOME="$H" "$D/config.sh" --unattended --replace --url "$REPO_URL" --token "$TOKEN" \
    --name fedora --labels fedora,libvirt,terraform --work _work
  unset TOKEN
fi

log "systemd unit (hardened)"
install -m 0644 "$HERE/gh-runner.service" /etc/systemd/system/gh-runner.service
systemctl daemon-reload
systemctl enable --now gh-runner.service
systemctl restart gh-runner.service

log "Verify"
sleep 8
systemctl is-active gh-runner.service
journalctl -u gh-runner.service -n 20 --no-pager | grep -E 'Connected to GitHub|Listening for Jobs' | tail -2 || true
sudo -u "$U" virsh -c qemu:///system list --all --name | grep -c . | sed 's/^/libvirt domains visible to runner: /'
sudo -u "$U" test -r "/home/$SRC_USER/.pgpass" && die "runner can read .pgpass" || echo "isolation: runner cannot read /home/$SRC_USER"
