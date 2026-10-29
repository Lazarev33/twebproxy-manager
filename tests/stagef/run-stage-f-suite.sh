#!/usr/bin/env bash
# 0=all mandatory checks executed/PASS; 1=FAIL; 77=INCOMPLETE.
# Stage F cases are model tests (tests/stagef/updater-harness.sh plus the Stage 4
# update fixtures): sandboxed paths, a modeled GitHub, ephemeral test keys; they
# change no system state and need no lab host (root for sandboxed chown/flock).
# Scope: f-scope-invariants.sh <v0.2.19 tree>.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
source "$ROOT/tests/lib/stage-a-results.sh"
stage_a_run_case "F updater: provenance, locking, install/rollback (MODEL)" "$ROOT/tests/stagef/updater-fixture.sh" 1500 "$MGR"
stage_a_run_case "Stage 4 update/backup fixture A-P under the Stage F trust policy (MODEL)" "$ROOT/tests/stage4-update-backup-fixture.sh" 900
stage_a_run_case "Stage 4 corrections fixture U-V (MODEL)" "$ROOT/tests/stage4-corrections-fixture.sh" 600
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) echo 'stage-f-suite: PASS (all mandatory model checks executed)';;
  77) echo 'stage-f-suite: INCOMPLETE (mandatory checks NOT_EXECUTED)';;
  *) echo 'stage-f-suite: FAIL';;
esac
exit "$rc"
