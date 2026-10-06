#!/usr/bin/env bash
# Acceptance for a workflow migrated to Chainguard Actions. Prints one PASS or FAIL line per check; exit 1 on any FAIL.
#   scripts/acceptance.sh .github/workflows/pipeline-hardened.yml
#   1  every action comes from chainguard-actions (local ./ actions excepted)
#   2  every reference is a full 40-character commit SHA
#   3  every pin carries its version as a comment (for people and Dependabot)
#   4  no reference to @main (hardened repositories keep only metadata there)
#   5  every executed file matches each action's signed provenance (scripts/verify-pins.sh)
#   6  the nested upstream actions an allowlist needs are listed (scripts/nested.sh)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
f=${1:?usage: acceptance.sh <workflow.yml>}
fail=0
check() { if [ "$2" = ok ]; then echo "PASS $1  $3"; else echo "FAIL $1  $3"; fail=1; fi; }

uses=$(grep -E '^[[:space:]]*(-[[:space:]]*)?uses:' "$f" | sed -E 's/^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*//')
total=$(echo "$uses" | grep -cv '^\./')
cg=$(echo "$uses" | grep -c '^chainguard-actions/')
check 1 "$([ "$total" -gt 0 ] && [ "$cg" -eq "$total" ] && echo ok)" "$cg of $total actions come from chainguard-actions"

sha=$(echo "$uses" | grep -cE '^chainguard-actions/[^@]+@[0-9a-f]{40}([[:space:]]|$)')
check 2 "$([ "$sha" -eq "$total" ] && echo ok)" "$sha of $total references are full commit SHAs"

cmt=$(echo "$uses" | grep -cE '@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v?[0-9]')
check 3 "$([ "$cmt" -eq "$total" ] && echo ok)" "$cmt of $total pins carry a version comment"

main=$(echo "$uses" | grep -cE '@(main|master)([[:space:]]|$)')
check 4 "$([ "$main" -eq 0 ] && echo ok)" "$main references to @main or @master"

pins=$("$here/verify-pins.sh" "$f" 2>/dev/null); rc=$?
n=$(echo "$pins" | grep -c '^chainguard-actions/')
check 5 "$([ $rc -eq 0 ] && [ "$n" -gt 0 ] && echo ok)" "$n actions: every executed file matches its provenance$([ $rc -ne 0 ] && echo ' (see scripts/verify-pins.sh)')"

nested=$("$here/nested.sh" "$f" 2>/dev/null | sed -n '/^Allowlist patterns/,$p' | tail -n +3)
k=$(echo "$nested" | grep -c '@')
check 6 "$([ "$cg" -gt 0 ] && echo ok)" "$k nested upstream actions to allow by SHA$([ "$k" -gt 0 ] && echo ": $(echo $nested | tr ' ' ',')")"

exit $fail
