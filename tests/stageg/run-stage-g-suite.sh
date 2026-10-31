#!/usr/bin/env bash
# 0=all mandatory checks executed/PASS; 1=FAIL; 77=INCOMPLETE.
# Stage G: process fixture (P1 regressions, model candidates with real
# processes/locks), the real-process oracle (real manager CLI, real curl/TLS on
# loopback, real flock/signals in sandboxes), the ACME webroot fixture (real
# kernel permission check) and the hostname validation fixture. Root required;
# nothing outside temporary sandboxes is touched. Scope: g-scope-invariants.sh
# <v0.2.20 tree>.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
source "$ROOT/tests/lib/stage-a-results.sh"
stage_a_run_case "G1-G3 updater probes, lock descriptor, restore metadata (MODEL + real processes)" "$ROOT/tests/stageg/process-fixture.sh" 1500 "$MGR"
stage_a_run_case "G real-process oracle A-C (REAL processes, curl/TLS, flock; sandboxed)" "$ROOT/tests/stageg/real-process-oracle.sh" 900 "$MGR"
stage_a_run_case "G4 ACME webroot traversal (MODEL frontend + real permission check)" "$ROOT/tests/stageg/acme-webroot-fixture.sh" 600 "$MGR"
stage_a_run_case "G5 hostname validation in mutating commands (MODEL)" "$ROOT/tests/stageg/input-validation-fixture.sh" 900 "$MGR"
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) echo 'stage-g-suite: PASS (all mandatory checks executed)';;
  77) echo 'stage-g-suite: INCOMPLETE (mandatory checks NOT_EXECUTED)';;
  *) echo 'stage-g-suite: FAIL';;
esac
exit "$rc"
