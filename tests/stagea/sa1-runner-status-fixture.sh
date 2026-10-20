#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d /tmp/twebproxy-runner-status.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/lib/stage-a-results.sh"
printf 'printf "PASS executed\\n"\n' > "$TMP/pass.sh"
printf 'printf "FAIL assertion\\n"\nexit 1\n' > "$TMP/fail.sh"
printf 'printf "NOT_EXECUTED required-check\\n"\nexit 77\n' > "$TMP/ne.sh"
printf 'printf "SKIP required-check\\n"\nexit 0\n' > "$TMP/legacy-skip.sh"
stage_a_run_case executed "$TMP/pass.sh" 5
stage_a_result
[[ "$STAGE_A_PASS" == 1 && "$STAGE_A_FAIL" == 0 && "$STAGE_A_NOT_EXECUTED" == 0 ]]
stage_a_run_case skipped "$TMP/ne.sh" 5 > "$TMP/ne.out"
rc=0; stage_a_result || rc=$?
[[ "$rc" == 77 && "$STAGE_A_NOT_EXECUTED" == 1 ]]
stage_a_run_case legacy-skipped "$TMP/legacy-skip.sh" 5 > "$TMP/legacy-ne.out"
rc=0; stage_a_result || rc=$?
[[ "$rc" == 77 && "$STAGE_A_NOT_EXECUTED" == 2 ]]
stage_a_run_case failed "$TMP/fail.sh" 5 > "$TMP/failed.out"
rc=0; stage_a_result || rc=$?
[[ "$rc" == 1 && "$STAGE_A_FAIL" == 1 ]]
printf 'PASS stage-a1-runner-status: PASS/FAIL/NOT_EXECUTED stay distinct\n'
