#!/usr/bin/env bash
# 0=all mandatory checks executed/PASS; 1=FAIL; 77=INCOMPLETE.
# Stage E cases are model tests (tests/stagee/ops-harness.sh): they change no
# system state and need no lab host. Scope: e-scope-invariants.sh <v0.2.18 tree>.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
source "$ROOT/tests/lib/stage-a-results.sh"
stage_a_run_case "E operations: TUI input, bounded/truthful diagnostics, reports (MODEL)" "$ROOT/tests/stagee/operations-fixture.sh" 1500 "$MGR"
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) echo 'stage-e-suite: PASS (all mandatory model checks executed)';;
  77) echo 'stage-e-suite: INCOMPLETE (mandatory checks NOT_EXECUTED)';;
  *) echo 'stage-e-suite: FAIL';;
esac
exit "$rc"
