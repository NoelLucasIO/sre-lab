#!/usr/bin/env bash
# Proves whether the S3 endpoint ENFORCES If-None-Match: * (what Terraform use_lockfile relies on).
# PASS = second create-only PUT gets 412. Anything else = the lockfile is not a mutex.
set -euo pipefail
BUCKET=${1:-backups}
EP=${EP:-http://127.0.0.1:3900}
REGION=${REGION:-garage}
# shellcheck disable=SC1090
source "$HOME/.config/garage/$BUCKET.env"
KEY="locktest-$(date +%s).tflock"
put(){ curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary "$2" \
        --aws-sigv4 "aws:amz:$REGION:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
        -H 'If-None-Match: *' "$EP/$BUCKET/$1"; }

first=$(put "$KEY" holder-A)
second=$(put "$KEY" holder-B)
curl -s -o /dev/null -X DELETE --aws-sigv4 "aws:amz:$REGION:s3" \
     --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "$EP/$BUCKET/$KEY"

echo "first create: $first   second create (should be 412): $second"
[[ $second == 412 ]] && echo "PASS: conditional writes enforced" || { echo "FAIL: lock would not exclude a second writer"; exit 1; }
