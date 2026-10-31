#!/usr/bin/env bash
# v0.2.23 pre-RC corrections: REAL-HOST suite on an installed, owner-marked
# disposable test host (tests/lib/lab-gate.sh: installed_host_gate_or_exit).
# 0 = all executed and PASS, 1 = FAIL, 77 = NOT_EXECUTED (gate refused).
# Destructive for the duration of the run: starts/stops nftables.service and the
# TWebProxy firewall, overmounts /etc/twebproxy/dpi with a tmpfs, marks
# /etc/twebproxy/global.env immutable and performs local test updates/rollbacks;
# every step restores the previous state. Usage: run-prerc-real-suite.sh <host> <out dir>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT/tests/lib/lab-gate.sh"
installed_host_gate_or_exit prerc-real-suite
H="${1:?hostname}"; OUT="$(realpath -m "${2:?out dir}")"; mkdir -p "$OUT"
rc=0
run() { local n="$1"; shift; "$@" > "$OUT/$n.log" 2>&1; local r=$?; printf '%-24s rc=%s  %s\n' "$n" "$r" "$(tail -1 "$OUT/$n.log")"; (( r == 0 )) || rc=1; }
run fw-transitions bash "$ROOT/tests/prerc/fw-transition-probe.sh" "$OUT/fw-transitions"
run guard-continuity bash "$ROOT/tests/prerc/guard-continuity-real.sh"
run restore-metadata python3 -I "$ROOT/tests/prerc/restore-metadata-real.py" "$OUT/restore-metadata"
run proc-secret bash "$ROOT/tests/prerc/proc-secret-real.sh"
run dpi-enospc bash "$ROOT/tests/prerc/dpi-enospc-real.sh" "$H"
run rollback-eof bash -c 'twebproxy manager-rollback latest </dev/null; r1=$?; printf "n\n" | twebproxy manager-rollback latest; r2=$?; echo "eof=$r1 declined=$r2"; (( r1 == 130 && r2 == 1 ))'
echo "prerc-real-suite: $([[ $rc == 0 ]] && echo PASS || echo FAIL)"; exit $rc
