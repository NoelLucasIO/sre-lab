#!/usr/bin/env bash
# Proves the pg backend lock actually excludes a second writer.
# PASS = a second run, started while the first holds the lock, fails with "Error acquiring the state lock".
set -euo pipefail
cd "$(dirname "$0")"
set -a
# shellcheck disable=SC1091
source "$HOME/.config/terraform/pg.env"
set +a
LOG=$(mktemp -d)

terraform init -input=false -reconfigure >/dev/null
terraform apply -auto-approve -input=false >"$LOG/holder.log" 2>&1 &
HOLDER=$!
sleep 6   # let the holder take the lock and start its 20s provisioner

if terraform plan -input=false -lock-timeout=0s >"$LOG/contender.log" 2>&1; then
  RESULT="FAIL: second writer got in while the lock was held"
elif grep -q 'Error acquiring the state lock' "$LOG/contender.log"; then
  RESULT="PASS: second writer refused ($(grep -m1 -o 'Lock Info' "$LOG/contender.log" || echo 'lock held'))"
else
  RESULT="INCONCLUSIVE: contender failed for another reason, see $LOG/contender.log"
fi
wait "$HOLDER" || { echo "holder apply failed, see $LOG/holder.log"; exit 1; }

terraform destroy -auto-approve -input=false >/dev/null
PGSSLROOTCERT=system psql -X -q "$PG_CONN_STR" -c 'DROP SCHEMA IF EXISTS locktest CASCADE'
rm -rf .terraform .terraform.lock.hcl

echo "$RESULT"
[[ $RESULT == PASS* ]]
