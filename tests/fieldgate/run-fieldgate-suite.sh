#!/usr/bin/env bash
# Field-gate correction pass 1 regression suite.
# Closes the audited test gaps TG-1, TG-3, TG-5 (+TG-5b) and the backend portion of
# TG-7,
# which correspond to findings TWP-001, TWP-002, TWP-003 and TWP-005.
#
# Usage: run-fieldgate-suite.sh [path/to/twebproxy-manager.sh]
#   With no argument the adjacent release manager is tested. Pass the audited
#   0.2.8-dpi-beta manager to confirm every gate still fails against it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TESTS="$ROOT/tests/fieldgate"

declare -a NAMES=(
  "TG-1/TWP-001 real-nft six-mode gate:tg1-real-nft-six-mode-gate.sh:300"
  "TG-3/TWP-002 installed-manager lifecycle:tg3-installed-manager-lifecycle.sh:600"
  "TG-5/TWP-003 DPI scope local-address gate:tg5-dpi-scope-local-address-gate.sh:300"
  "TG-5b/TWP-003 production-errexit control flow:tg5b-errexit-control-flow.sh:300"
  "TG-7/TWP-005 backend state isolation:tg7-backend-state-isolation.sh:300"
  "FD-1 field diagnostics (field-report):fd1-field-report.sh:900"
  "DF-3 DPI cleanup + stage diagnostics:df3-dpi-cleanup-stage-diagnostics.sh:600"
  "DF-3b nfqws cleanup failure propagation:df3b-nfqws-cleanup-propagation.sh:300"
)
rc=0
for entry in "${NAMES[@]}"; do
  label="${entry%%:*}"; rest="${entry#*:}"; script="${rest%%:*}"; tmo="${rest##*:}"
  printf '\n===== %s =====\n' "$label"
  if timeout "$tmo" bash "$TESTS/$script" "$MGR"; then
    printf '%s: PASS\n' "$label"
  else
    status=$?
    if (( status == 124 )); then printf '%s: FAIL (timed out after %ss)\n' "$label" "$tmo" >&2
    else printf '%s: FAIL (exit %s)\n' "$label" "$status" >&2; fi
    rc=1
  fi
done
printf '\nfieldgate-suite: %s\n' "$( ((rc==0)) && echo 'PASS (TG-1, TG-3, TG-5, TG-5b, TG-7-backend, FD-1, DF-3, DF-3b)' || echo FAIL )"
exit "$rc"
