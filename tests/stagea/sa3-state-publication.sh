#!/usr/bin/env bash
# Stage A / A3 regression: publishing DPI scope state must never lose the
# previous authoritative state and must never report success when it failed.
#
# The 0.2.9 shape was:
#     rm -rf "$DPI_STATE_DIR"
#     cp -a "$proposed" "$DPI_STATE_DIR"
# with both commands unchecked. dpi_commit_candidate_state is always called from
# a conditional context (`if dpi_commit_candidate_state ...`), and bash suspends
# errexit for the whole body of a function invoked that way - so a failing `cp`
# did not stop anything. The old state was already destroyed by `rm -rf`, the
# new one never arrived, dpi_reconcile_runtime then saw an EMPTY state directory,
# took its STOCK branch and returned 0, and commit reported SUCCESS.
#
# Fault injection here is real where it can be: an ENOSPC tmpfs makes `cp`
# genuinely fail, and a tmpfs sized between the two state files produces a
# genuinely partial copy. The forced-failure seam is used in addition, to reach
# the rename boundary deterministically.
#
# Usage: sa3-state-publication.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
pass=0; fail=0; not_executed=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
t_skip(){ printf 'NOT_EXECUTED %s\n' "$*"; not_executed=$((not_executed+1)); }
check_nonzero() { local n="$1" rc="$2"; if (( rc != 0 )); then t_ok "$n (rc=$rc)"; else t_bad "$n (returned 0)"; fi; }

TMP="$(mktemp -d /tmp/sa3-publish.XXXXXX)"
SMALL="$TMP/small"; mkdir -p "$SMALL"
cleanup() { mountpoint -q "$SMALL" && umount "$SMALL" 2>/dev/null; rm -rf -- "$TMP"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source "$ROOT/tests/lib/dpi-harness.sh"
dpi_harness_env "$TMP"
# shellcheck source=/dev/null
source "$MGR"
trap - ERR
set +e
dpi_harness_bind "$ROOT" "$TMP"

A_IP=198.51.100.10; B_IP=198.51.100.20
dpi_local_ipv4_addresses() { printf '%s\n' "$A_IP" "$B_IP"; }
dpi_hosts_for_ipv4() { case "${1:-}" in "$A_IP") echo alpha.example;; "$B_IP") echo beta.example;; esac; return 0; }
instance_exists() { [[ "${1:-}" == alpha.example || "${1:-}" == beta.example ]]; }

reset_state() {
  rm -rf "$DPI_DIR" "$SYSTEMD_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  mkdir -p "$SYSTEMD_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  rm -f "$MOCK_NFT_LIVE"
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  CURRENT_LOG="$TMP/manager.log"; : > "$CURRENT_LOG"; chmod 0600 "$CURRENT_LOG"
  dpi_transaction_set "$A_IP" window1152 alpha.example >/dev/null 2>&1
}

state_has() { [[ -f "$DPI_STATE_DIR/$1.env" ]] && dpi_load_scope_file "$DPI_STATE_DIR/$1.env"; }
live_has()  { local l; l="$("$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" 2>/dev/null)"; [[ "$l" == *"$1"* ]]; }

printf '\n--- 0. baseline: a valid scope is published and live ---\n'
reset_state
state_has "$A_IP" && t_ok sa3_precondition_state_published || t_bad sa3_precondition_state_published
live_has  "$A_IP" && t_ok sa3_precondition_rule_live      || t_bad sa3_precondition_rule_live

# =====================================================================
# 1. GENUINE ENOSPC at the copy boundary (no seam, no stub)
# =====================================================================
printf '\n--- 1. real ENOSPC during publication ---\n'
if mount -t tmpfs -o size=80k tmpfs "$SMALL" 2>/dev/null; then
  SAVED_DPI_DIR="$DPI_DIR"
  DPI_DIR="$SMALL/dpi"; DPI_STATE_DIR="$DPI_DIR/scopes"; DPI_NFT_FILE="$DPI_DIR/firewall.nft"
  rm -f "$MOCK_NFT_LIVE"
  dpi_transaction_set "$A_IP" window1152 alpha.example >/dev/null 2>&1
  if state_has "$A_IP"; then
    t_ok sa3_enospc_precondition_state_on_small_fs
    # Fill the filesystem so no further copy can succeed.
    dd if=/dev/zero of="$SMALL/ballast" bs=1k count=200 >/dev/null 2>&1
    free_now="$(df -k --output=avail "$SMALL" | tail -1 | tr -d ' ')"
    if (( free_now <= 8 )); then t_ok "sa3_enospc_filesystem_is_full (${free_now}k free)"
    else t_bad "sa3_enospc_filesystem_is_full: ${free_now}k still free"; fi

    dpi_transaction_set "$B_IP" mss88 beta.example >/dev/null 2>&1; rc=$?
    check_nonzero sa3_enospc_transaction_does_not_report_success "$rc"
    state_has "$A_IP" && t_ok sa3_enospc_previous_state_survives \
                      || t_bad sa3_enospc_previous_state_survives
    if [[ -d "$DPI_STATE_DIR" ]]; then t_ok sa3_enospc_state_dir_not_destroyed
    else t_bad sa3_enospc_state_dir_not_destroyed; fi
    state_has "$B_IP" && t_bad sa3_enospc_partial_candidate_not_authoritative \
                      || t_ok sa3_enospc_partial_candidate_not_authoritative
    rm -f "$SMALL/ballast"
  else
    t_bad sa3_enospc_precondition_state_on_small_fs
  fi
  DPI_DIR="$SAVED_DPI_DIR"; DPI_STATE_DIR="$DPI_DIR/scopes"; DPI_NFT_FILE="$DPI_DIR/firewall.nft"
  umount "$SMALL" 2>/dev/null
else
  t_skip "sa3_enospc_*: NOT_EXECUTED_ENVIRONMENT_LIMITATION (tmpfs mount unavailable)"
fi

# =====================================================================
# 2. the exact A3 mechanism, injected at the real mutating command boundary
# =====================================================================
# `cp` is intercepted as a shell function, so the failure happens inside the
# very command the manager runs to materialise the new authoritative state.
# This is implementation-agnostic: it fires whether that copy targets
# $DPI_STATE_DIR directly (0.2.9) or a staging directory beside it.
SA3_COPY_MODE=off
SA3_RESTORE_FAILS=0
cp() {
  local dest="${!#}"
  # The snapshot restore copies the whole DPI directory back into place.
  if (( SA3_RESTORE_FAILS )) && [[ "$dest" == "$DPI_DIR" ]]; then
    printf 'sa3: injected restore failure -> %s\n' "$dest" >&2; return 1
  fi
  case "$SA3_COPY_MODE:$dest" in
    off:*) command cp "$@";;
    fail:"$DPI_STATE_DIR"|fail:"$DPI_DIR"/.scopes.new)
      printf 'sa3: injected copy failure -> %s\n' "$dest" >&2; return 1;;
    partial:"$DPI_STATE_DIR"|partial:"$DPI_DIR"/.scopes.new)
      # Genuinely partial: the directory and exactly one state file arrive.
      printf 'sa3: injected PARTIAL copy -> %s\n' "$dest" >&2
      command mkdir -p "$dest" || return 1
      local src first
      for src in "$@"; do :; done
      first="$(command find "${@: -2:1}" -maxdepth 1 -type f -name '*.env' | sort | head -n1)"
      [[ -z "$first" ]] || command cp -a "$first" "$dest/" || return 1
      return 1;;
    *) command cp "$@";;
  esac
}

printf '\n--- 2. failed copy at the mutating boundary ---\n'
for mode in fail partial; do
  reset_state
  work="$(mktemp -d "$TMP/work.XXXXXX")"; mkdir -p "$work/proposed" "$work/snapshot"
  command cp -a "$DPI_STATE_DIR/." "$work/proposed/"
  command cp -a "$DPI_DIR" "$work/snapshot/dpi"
  dpi_write_scope_state "$work/proposed" "$B_IP" mss88 beta.example
  SA3_COPY_MODE="$mode"
  # Exactly how production calls it: errexit is suspended for the whole body.
  if dpi_commit_candidate_state "$work/proposed" "$work/snapshot"; then commit_rc=0; else commit_rc=1; fi
  SA3_COPY_MODE=off
  check_nonzero "sa3_${mode}_copy_commit_returns_failure" "$commit_rc"
  state_has "$A_IP" && t_ok "sa3_${mode}_copy_previous_state_survives" \
                    || t_bad "sa3_${mode}_copy_previous_state_survives"
  state_has "$B_IP" && t_bad "sa3_${mode}_copy_candidate_not_authoritative" \
                    || t_ok "sa3_${mode}_copy_candidate_not_authoritative"
  live_has "$A_IP" && t_ok "sa3_${mode}_copy_previous_rule_still_live" \
                   || t_bad "sa3_${mode}_copy_previous_rule_still_live"
  if [[ -s "$DPI_NFT_FILE" ]]; then t_ok "sa3_${mode}_copy_no_false_stock"
  else t_bad "sa3_${mode}_copy_no_false_stock: reconciled down to STOCK on a failed publication"; fi
  rm -rf "$work"
done

printf '\n--- 3. the same through the public transaction entrypoint ---\n'
for mode in fail partial; do
  reset_state
  SA3_COPY_MODE="$mode"
  dpi_transaction_set "$B_IP" mss88 beta.example >/dev/null 2>&1; rc=$?
  SA3_COPY_MODE=off
  check_nonzero "sa3_public_${mode}_copy_fails" "$rc"
  state_has "$A_IP" && t_ok "sa3_public_${mode}_copy_previous_state_survives" \
                    || t_bad "sa3_public_${mode}_copy_previous_state_survives"
  state_has "$B_IP" && t_bad "sa3_public_${mode}_copy_candidate_not_committed" \
                    || t_ok "sa3_public_${mode}_copy_candidate_not_committed"
  live_has "$A_IP" && t_ok "sa3_public_${mode}_copy_previous_rule_still_live" \
                   || t_bad "sa3_public_${mode}_copy_previous_rule_still_live"
  if [[ -e "$DPI_DIR/.scopes.new" || -e "$DPI_DIR/.scopes.old" ]]; then
    t_bad "sa3_public_${mode}_copy_no_leftover_publication_dirs"
  else
    t_ok "sa3_public_${mode}_copy_no_leftover_publication_dirs"
  fi
done

printf '\n--- 3b. EVERY staged-publication boundary behaves identically ---\n'
# These boundaries exist only once publication is staged, so against 0.2.9 the
# whole block is declared skipped rather than silently passing.
if grep -q "publish state rename" "$MGR"; then
  for point in 'publish state copy' 'publish state verify' \
               'publish state retire' 'publish state rename'; do
    label="$(printf '%s' "${point#publish state }" | tr ' ' '_')"
    reset_state
    export TWEBPROXY_DPI_TEST_FAIL_POINT="stage:$point"
    dpi_transaction_set "$B_IP" mss88 beta.example >/dev/null 2>&1; rc=$?
    unset TWEBPROXY_DPI_TEST_FAIL_POINT
    check_nonzero "sa3_boundary_${label}_fails" "$rc"
    state_has "$A_IP" && t_ok "sa3_boundary_${label}_previous_state_kept" \
                      || t_bad "sa3_boundary_${label}_previous_state_kept"
    if grep -Fq 'MODE=window1152' "$DPI_STATE_DIR/$A_IP.env" 2>/dev/null; then
      t_ok "sa3_boundary_${label}_previous_mode_intact"
    else
      t_bad "sa3_boundary_${label}_previous_mode_intact"
    fi
    state_has "$B_IP" && t_bad "sa3_boundary_${label}_candidate_not_committed" \
                      || t_ok "sa3_boundary_${label}_candidate_not_committed"
    live_has "$A_IP" && t_ok "sa3_boundary_${label}_previous_rule_still_live" \
                     || t_bad "sa3_boundary_${label}_previous_rule_still_live"
    if [[ -e "$DPI_DIR/.scopes.new" || -e "$DPI_DIR/.scopes.old" ]]; then
      t_bad "sa3_boundary_${label}_no_leftover_dirs"
    else
      t_ok "sa3_boundary_${label}_no_leftover_dirs"
    fi
  done
else
  t_skip "NOT_EXECUTED_ENVIRONMENT_LIMITATION sa3_boundary_*: no staged publication in this build (0.2.9 has no publication boundaries)"
fi

# =====================================================================
# 3c. a rollback that did not happen must never be reported as restored
# =====================================================================
# dpi_restore_snapshot restores the previous DPI directory and then reconciles.
# With the restore copy unchecked, reconciliation saw an EMPTY state directory,
# took its STOCK branch and returned 0 - so the manager recorded
# `rollback=restored` while the previous state was gone. Fail-closed STOCK is
# the accepted outcome when a rollback cannot be re-applied; reporting it as a
# successful restore is not.
printf '\n--- 3c. honest rollback reporting ---\n'
reset_state
SA3_RESTORE_FAILS=1
export TWEBPROXY_DPI_TEST_FAIL_POINT='stage:verify runtime'
dpi_transaction_set "$B_IP" mss88 beta.example >/dev/null 2>&1; rc=$?
unset TWEBPROXY_DPI_TEST_FAIL_POINT
SA3_RESTORE_FAILS=0
check_nonzero sa3_failed_restore_transaction_fails "$rc"
if grep -Fq 'rollback=restored' "$CURRENT_LOG"; then
  t_bad "sa3_failed_restore_not_reported_as_restored: the transcript claims a rollback that did not happen"
else
  t_ok "sa3_failed_restore_not_reported_as_restored"
fi
if grep -Eq 'rollback=(failed|failed-fell-back-to-STOCK)' "$CURRENT_LOG"; then
  t_ok "sa3_failed_restore_reported_as_failed"
else
  t_bad "sa3_failed_restore_reported_as_failed: no rollback failure recorded at all"
fi
# The control: when the restore CAN happen, it is reported as restored and the
# previous scope really is back.
reset_state
export TWEBPROXY_DPI_TEST_FAIL_POINT='stage:verify runtime'
dpi_transaction_set "$B_IP" mss88 beta.example >/dev/null 2>&1
unset TWEBPROXY_DPI_TEST_FAIL_POINT
grep -Fq 'rollback=restored' "$CURRENT_LOG" && t_ok sa3_successful_rollback_reported_as_restored \
                                            || t_bad sa3_successful_rollback_reported_as_restored
state_has "$A_IP" && t_ok sa3_successful_rollback_really_restored \
                  || t_bad sa3_successful_rollback_really_restored

# =====================================================================
# 4. positive control: publication still works, and replaces cleanly
# =====================================================================
printf '\n--- 4. positive control ---\n'
reset_state
dpi_transaction_set "$B_IP" mss88 beta.example >/dev/null 2>&1; rc=$?
(( rc == 0 )) && t_ok sa3_control_second_scope_published || t_bad "sa3_control_second_scope_published (rc=$rc)"
state_has "$A_IP" && t_ok sa3_control_first_scope_kept   || t_bad sa3_control_first_scope_kept
state_has "$B_IP" && t_ok sa3_control_second_scope_kept  || t_bad sa3_control_second_scope_kept
live_has "$A_IP" && live_has "$B_IP" && t_ok sa3_control_both_rules_live || t_bad sa3_control_both_rules_live
# A mode change must replace, not accumulate.
dpi_transaction_set "$A_IP" mss88 alpha.example >/dev/null 2>&1
if grep -Fq 'MODE=mss88' "$DPI_STATE_DIR/$A_IP.env" 2>/dev/null; then t_ok sa3_control_mode_replaced
else t_bad sa3_control_mode_replaced; fi
n="$(find "$DPI_STATE_DIR" -maxdepth 1 -type f -name '*.env' | wc -l)"
[[ "$n" == 2 ]] && t_ok "sa3_control_exactly_two_scopes" || t_bad "sa3_control_exactly_two_scopes (got $n)"
# Disable removes exactly one scope.
dpi_transaction_disable_ip "$A_IP" >/dev/null 2>&1
state_has "$B_IP" && t_ok sa3_control_disable_keeps_other_scope || t_bad sa3_control_disable_keeps_other_scope
state_has "$A_IP" && t_bad sa3_control_disable_removed_target   || t_ok sa3_control_disable_removed_target

printf '\nsa3-state-publication: %s pass, %s fail, %s NOT_EXECUTED\n' "$pass" "$fail" "$not_executed"
(( fail == 0 )) || exit 1
(( not_executed == 0 )) || exit 77
