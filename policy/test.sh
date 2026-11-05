#!/usr/bin/env bash
# Proves each custom Checkov policy catches its violation (bad/) and passes compliant code (good/).
# A policy that passes everything is indistinguishable from no policy; this is the check on that.
set -euo pipefail
cd "$(dirname "$0")"
CHECKS=$(sed -n 's/^  id: "\(CKV2_SRELAB_[0-9]*\)"/\1/p' checkov/*.yaml | paste -sd, -)
run(){ checkov -d "checkov/tests/$1" --framework terraform --external-checks-dir checkov \
         --check "$CHECKS" -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin); d = d if isinstance(d, list) else [d]
r = d[0]["results"]
print(" ".join(sorted({c["check_id"] for c in r["passed_checks"]})), "|",
      " ".join(sorted({c["check_id"] for c in r["failed_checks"]})))'; }
want=$(tr , ' ' <<<"$CHECKS")
IFS='|' read -r bp bf <<<"$(run bad)";  IFS='|' read -r gp gf <<<"$(run good)"
fail=0
for c in $want; do
  [[ " $bf " == *" $c "* ]] && b=ok || { b=MISSED; fail=1; }
  [[ " $gp " == *" $c "* ]] && g=ok || { g=FALSE-POSITIVE; fail=1; }
  printf '%-14s catches-violation=%-6s passes-compliant=%s\n' "$c" "$b" "$g"
done
exit $fail
