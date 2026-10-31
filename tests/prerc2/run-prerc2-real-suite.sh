#!/usr/bin/env bash
# v0.2.24 focused security correction: REAL-HOST gates for P1-A and P1-B on an
# installed, owner-marked disposable test host. 0 = all GREEN, 1 = RED/FAIL,
# 77 = NOT_EXECUTED. Destructive while it runs (kills the guard owner, flushes
# the ruleset, restarts services, briefly unprotects /proc); restores the
# steady state with the manager under test.
# Usage: TWEBPROXY_PRERC_REAL=installed-test-host run-prerc2-real-suite.sh <manager script> <out dir> [--quick]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/../lib/lab-gate.sh"
installed_host_gate_or_exit prerc2-real-suite
M="$(realpath "${1:?manager script}")"; OUT="$(realpath -m "${2:?out dir}")"; Q="${3:-}"
mkdir -p "$OUT"; rc=0
run() { local n="$1"; shift; "$@" > "$OUT/$n.log" 2>&1; local r=$?; printf '%-22s rc=%s  %s\n' "$n" "$r" "$(tail -1 "$OUT/$n.log")"
  (( r == 0 )) || rc=1; (( r != 77 )) || rc=77; }
run start-gate-fixture bash "$HERE/start-gate-fixture.sh"
run fw-owner-loss python3 -I "$HERE/fw_owner_loss_probe.py" "$OUT/fw-owner-loss" $Q
python3 -I "$HERE/no_table_windows.py" "$OUT/fw-owner-loss" > "$OUT/no-table-windows.log" 2>&1 || true
run proc-fail-closed bash "$HERE/proc_fail_closed_probe.sh" "$M" "$OUT/proc-fail-closed"
echo "prerc2-real-suite: $([[ $rc == 0 ]] && echo PASS || echo FAIL)"; exit $rc
