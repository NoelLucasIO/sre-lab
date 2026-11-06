#!/usr/bin/env bash
# Policy: every container image in the rendered manifests (stdin) is pinned as name:tag@sha256:<digest>,
# and no tag is `latest`. A digest is what makes "roll back to the previous version" mean something.
set -euo pipefail
imgs=$(grep -E '^[[:space:]-]*image:[[:space:]]' | sed -E 's/^[[:space:]-]*image:[[:space:]]*//; s/["'\'']//g' | sort -u) || true
[ -n "$imgs" ] || { echo "::error::no images found in rendered manifests"; exit 1; }
bad=0
while read -r i; do
  if [[ ! $i =~ ^[^@[:space:]]+:[^:@/[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
    echo "::error::image not pinned as name:tag@sha256:<digest>: $i"; bad=1
  elif [[ $i == *:latest@* ]]; then
    echo "::error::image uses the latest tag: $i"; bad=1
  else
    echo "ok: $i"
  fi
done <<< "$imgs"
exit "$bad"
