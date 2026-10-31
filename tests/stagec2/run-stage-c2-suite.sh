#!/usr/bin/env bash
# 0=all mandatory checks executed/PASS; 1=FAIL; 77=INCOMPLETE.
# Stage C2 cases are model tests (tests/stagec2/relay-harness.sh): they change
# no system state and need no lab host. Scope: c2-scope-invariants.sh <v0.2.16 tree>.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
source "$ROOT/tests/lib/stage-a-results.sh"
stage_a_run_case "C2 relay update / restart / delete lifecycle (MODEL)" "$ROOT/tests/stagec2/relay-lifecycle-fixture.sh" 900 "$MGR"
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) echo 'stage-c2-suite: PASS (all mandatory model checks executed)';;
  77) echo 'stage-c2-suite: INCOMPLETE (mandatory checks NOT_EXECUTED)';;
  *) echo 'stage-c2-suite: FAIL';;
esac
exit "$rc"
