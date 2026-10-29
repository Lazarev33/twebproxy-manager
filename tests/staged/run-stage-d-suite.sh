#!/usr/bin/env bash
# 0=all mandatory checks executed/PASS; 1=FAIL; 77=INCOMPLETE.
# Stage D cases are model tests (tests/staged/frontend-harness.sh): they change
# no system state and need no lab host. Scope: d-scope-invariants.sh <v0.2.17 tree>.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
source "$ROOT/tests/lib/stage-a-results.sh"
stage_a_run_case "D frontend (Caddy/Nginx) and TLS lifecycle (MODEL)" "$ROOT/tests/staged/frontend-tls-fixture.sh" 900 "$MGR"
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) echo 'stage-d-suite: PASS (all mandatory model checks executed)';;
  77) echo 'stage-d-suite: INCOMPLETE (mandatory checks NOT_EXECUTED)';;
  *) echo 'stage-d-suite: FAIL';;
esac
exit "$rc"
