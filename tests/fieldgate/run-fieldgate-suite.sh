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
# 0=all executed/PASS; 1=FAIL; 77=INCOMPLETE. TG-1 and TG-3 touch the kernel
# or real mount points and run only on a disposable lab host (tests/LAB.md).
source "$ROOT/tests/lib/stage-a-results.sh"
for entry in "${NAMES[@]}"; do
  label="${entry%%:*}"; rest="${entry#*:}"; script="${rest%%:*}"; tmo="${rest##*:}"
  printf '\n===== %s =====\n' "$label"
  stage_a_run_case "$label" "$TESTS/$script" "$tmo" "$MGR"
done
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) printf '\nfieldgate-suite: PASS (TG-1, TG-3, TG-5, TG-5b, TG-7-backend, FD-1, DF-3, DF-3b)\n';;
  77) printf '\nfieldgate-suite: INCOMPLETE (lab-only checks NOT_EXECUTED)\n';;
  *) printf '\nfieldgate-suite: FAIL\n';;
esac
exit "$rc"
