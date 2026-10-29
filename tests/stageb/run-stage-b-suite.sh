#!/usr/bin/env bash
# 0=all mandatory checks executed/PASS; 1=FAIL; 77=INCOMPLETE.
# Model/static cases always run. REAL cases need a disposable lab host
# (tests/LAB.md); everywhere else they report NOT_EXECUTED and the suite stays
# INCOMPLETE - it never turns a missing kernel/systemd check into PASS.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
source "$ROOT/tests/lib/stage-a-results.sh"
stage_a_run_case "B transactional control flow (MODEL)" "$ROOT/tests/stageb/transaction-fixture.sh" 90 "$MGR"
stage_a_run_case "B.1 LIBEXEC_DIR permissions F1 (MODEL)" "$ROOT/tests/stageb/libexec-permissions-fixture.sh" 90 "$MGR"
stage_a_run_case "B.1 nft apply ambiguity R3 (MODEL)" "$ROOT/tests/stageb/apply-ambiguity-fixture.sh" 90 "$MGR"
stage_a_run_case "B.1 firewall unit contract R1 (STATIC)" "$ROOT/tests/stageb/firewall-unit-fixture.sh" 60 "$MGR"
stage_a_run_case "B.1 privileged test gate R5" "$ROOT/tests/stageb/lab-gate-fixture.sh" 900 "$MGR"
stage_a_run_case "B semantic JSON verifier (SCHEMA)" "$ROOT/tests/stageb/json-verifier-fixture.sh" 60 "$MGR"
stage_a_run_case "B backend state isolation TG7" "$ROOT/tests/fieldgate/tg7-backend-state-isolation.sh" 90 "$MGR"
stage_a_run_case "B actual kernel transactions (REAL, lab only)" "$ROOT/tests/stageb/real-nft-validation.sh" 150 "$MGR"
stage_a_run_case "B systemd lifecycle (REAL, lab only)" "$ROOT/tests/stageb/real-systemd-validation.sh" 270 "$MGR"
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) echo 'stage-b-suite: PASS (all mandatory checks executed)';;
  77) echo 'stage-b-suite: INCOMPLETE (mandatory real validation NOT_EXECUTED)';;
  *) echo 'stage-b-suite: FAIL';;
esac
exit "$rc"
