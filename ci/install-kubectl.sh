#!/usr/bin/env bash
# Install a pinned, sha256-verified kubectl into DIR (cached by version) and add DIR to PATH for
# later workflow steps.  Usage: KUBECTL_VERSION=v1.37.2 KUBECTL_SHA256=<sum> ci/install-kubectl.sh DIR
set -euo pipefail
dir=${1:?usage: install-kubectl.sh DIR}
v=${KUBECTL_VERSION:?} sum=${KUBECTL_SHA256:?}
bin="$dir/kubectl-$v"
if ! { [ -x "$bin" ] && echo "$sum  $bin" | sha256sum -c --quiet - >/dev/null 2>&1; }; then
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.kubectl.XXXXXX")
  curl -fsSLo "$tmp" "https://dl.k8s.io/release/$v/bin/linux/amd64/kubectl"
  echo "$sum  $tmp" | sha256sum -c --quiet - || { rm -f "$tmp"; echo "::error::kubectl $v checksum mismatch"; exit 1; }
  chmod 755 "$tmp" && mv "$tmp" "$bin"
fi
ln -sfn "$bin" "$dir/kubectl"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$dir" >> "$GITHUB_PATH"; fi
"$dir/kubectl" version --client
