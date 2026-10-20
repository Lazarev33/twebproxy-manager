#!/usr/bin/env bash
# Test-only result protocol: 0=all executed and passed, 1=failed, 77=incomplete.
STAGE_A_PASS=0 STAGE_A_FAIL=0 STAGE_A_NOT_EXECUTED=0
stage_a_run_case() {
  local label="$1" script="$2" limit="$3" mgr="${4:-}" out rc=0
  out="$(mktemp /tmp/twebproxy-stage-a-result.XXXXXX)" || return 1
  if timeout "$limit" bash "$script" "$mgr" > "$out" 2>&1; then :; else rc=$?; fi
  cat "$out"
  if (( rc != 0 && rc != 77 )); then
    STAGE_A_FAIL=$((STAGE_A_FAIL+1)); printf '%s: FAIL (rc=%s)\n' "$label" "$rc"
  elif (( rc == 77 )) || grep -Eq '^(SKIP|NOT_EXECUTED|INCOMPLETE)([ :]|$)' "$out"; then
    STAGE_A_NOT_EXECUTED=$((STAGE_A_NOT_EXECUTED+1)); printf '%s: NOT_EXECUTED\n' "$label"
  else
    STAGE_A_PASS=$((STAGE_A_PASS+1)); printf '%s: PASS\n' "$label"
  fi
  rm -f -- "$out"
}
stage_a_result() {
  printf 'stage-a-results: PASS=%s FAIL=%s NOT_EXECUTED=%s\n' "$STAGE_A_PASS" "$STAGE_A_FAIL" "$STAGE_A_NOT_EXECUTED"
  (( STAGE_A_FAIL == 0 )) || return 1
  (( STAGE_A_NOT_EXECUTED == 0 )) || return 77
  return 0
}
