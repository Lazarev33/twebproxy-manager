#!/usr/bin/env bash
# 0=all mandatory checks executed/PASS; 1=FAIL; 77=INCOMPLETE.
# Stage C1 cases are model tests (tests/stagec1/state-harness.sh): they change
# no system state and need no lab host. Scope: c1-scope-invariants.sh <v0.2.13 tree>.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
source "$ROOT/tests/lib/stage-a-results.sh"
stage_a_run_case "C1 profile identity F03 (MODEL)" "$ROOT/tests/stagec1/profile-identity-fixture.sh" 120 "$MGR"
stage_a_run_case "C1 state persistence F04 (MODEL)" "$ROOT/tests/stagec1/state-persistence-fixture.sh" 300 "$MGR"
stage_a_run_case "C1 concurrent mutation F05 (MODEL)" "$ROOT/tests/stagec1/concurrency-fixture.sh" 300 "$MGR"
stage_a_run_case "C1 port allocation F13 (MODEL)" "$ROOT/tests/stagec1/port-allocation-fixture.sh" 300 "$MGR"
stage_a_run_case "C1.1 backend stop / orphan reconciliation (MODEL)" "$ROOT/tests/stagec1/backend-stop-fixture.sh" 600 "$MGR"
stage_a_run_case "C1.2 backend identity / ownership (MODEL)" "$ROOT/tests/stagec1/backend-identity-fixture.sh" 600 "$MGR"
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) echo 'stage-c1-suite: PASS (all mandatory model checks executed)';;
  77) echo 'stage-c1-suite: INCOMPLETE (mandatory checks NOT_EXECUTED)';;
  *) echo 'stage-c1-suite: FAIL';;
esac
exit "$rc"
