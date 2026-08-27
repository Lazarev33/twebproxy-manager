#!/usr/bin/env bash
# DF-3b regression: a refused removal of the TWebProxy-owned nfqws runtime files
# must propagate as a cleanup failure.
#
# The accepted fielddiag2 contract was:
#     dpi_remove_owned_nfqws_runtime_files || return 1
# inside dpi_cleanup_nfqws_runtime. The first Field Fix 3 candidate replaced that
# with a bare `|| dpi_stage_fail ...`; dpi_stage_fail only logs and returns 0, and
# the function's `return "$rc"` carried only the unit-teardown result. A refused
# removal was therefore logged as result=failed while the function returned 0 -
# weaker than the baseline and self-contradictory in the transcript.
#
# This pins the whole chain, not just the leaf:
#   dpi_remove_owned_nfqws_runtime_files -> dpi_cleanup_nfqws_runtime
#     -> dpi_cleanup_stock_runtime -> dpi_reconcile_runtime -> the transaction
# and pins that the per-unit systemd teardown still runs, and that a healthy
# system is unaffected.
#
# The failure is forced through the guard's own real conditions - a directory
# where the owned binary belongs, and a symlinked libexec parent - not by
# stubbing the function out.
#
# Usage: df3b-nfqws-cleanup-propagation.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check()     { local n="$1"; shift; if "$@"; then t_ok "$n"; else t_bad "$n"; fi; }
check_not() { local n="$1"; shift; if "$@"; then t_bad "$n"; else t_ok "$n"; fi; }
check_nonzero() { local n="$1" rc="$2"; if (( rc != 0 )); then t_ok "$n (rc=$rc)"; else t_bad "$n (returned 0)"; fi; }
check_zero()    { local n="$1" rc="$2"; if (( rc == 0 )); then t_ok "$n"; else t_bad "$n (rc=$rc)"; fi; }

TMP="$(mktemp -d /tmp/df3b-nfqws.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT

export TWEBPROXY_NO_LOG=1 TWEBPROXY_UI_LANGUAGE=en
export TWEBPROXY_LANGUAGE_FILE="$TMP/ui-language"
export TWEBPROXY_DPI_DIR="$TMP/etc/dpi"
export TWEBPROXY_DPI_DOC_DIR="$TMP/doc"
export TWEBPROXY_NFT_BIN="$TMP/bin/nft"
mkdir -p "$TMP/bin" "$TMP/systemd" "$TMP/doc"
cat > "$TMP/bin/nft" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
live="${MOCK_NFT_LIVE:?}"
if [[ "${1:-}" == -c && "${2:-}" == -f ]]; then grep -q '^table ip twebproxy_dpi {' "$3"
elif [[ "${1:-}" == -f ]]; then cp "$2" "$live"
elif [[ "${1:-}" == list ]]; then [[ -s "$live" ]] || exit 1; cat "$live"
elif [[ "${1:-}" == delete ]]; then rm -f "$live"; else exit 2; fi
MOCK
chmod 0755 "$TMP/bin/nft"; export MOCK_NFT_LIVE="$TMP/live.nft"

# shellcheck source=/dev/null
source "$MGR"
trap - ERR
set +e

BASE_DIR="$TMP/etc"; INSTANCES_DIR="$TMP/instances"; mkdir -p "$INSTANCES_DIR"
DPI_DIR="$TWEBPROXY_DPI_DIR"; DPI_STATE_DIR="$DPI_DIR/scopes"
DPI_NFT_FILE="$DPI_DIR/firewall.nft"; DPI_NFT_BIN="$TMP/bin/nft"
DPI_DOC_DIR="$TMP/doc"; SYSTEMD_DIR="$TMP/systemd"
DPI_FIREWALL_UNIT=twebproxy-dpi-firewall.service
DPI_NFQWS_UNIT=twebproxy-dpi-nfqws.service
UI_LANGUAGE=en

SYSTEMCTL_ACTIVE_DIR="$TMP/systemctl-active"
SYSTEMCTL_LOG="$TMP/systemctl.log"
SYSTEMCTL_TRACE="$TMP/systemctl-trace.log"
# shellcheck source=/dev/null
source "$ROOT/tests/lib/systemctl-model.sh"

id() { [[ "${1:-}" == twebproxy-dpi ]] && return 0; command id "$@"; }
useradd() { return 0; }; userdel() { return 0; }
dpi_local_ipv4_addresses() { printf '198.51.100.10\n'; }
dpi_hosts_for_ipv4() { printf 'alpha.example\n'; return 0; }
SCOPE_IP=198.51.100.10

# Wire libexec the way a real deployment does: DPI_NFQWS_BIN and its checksum
# always live inside LIBEXEC_DIR. Anything else is not a configuration the
# manager can be installed into.
use_libexec() {
  LIBEXEC_DIR="$1"
  DPI_NFQWS_BIN="$LIBEXEC_DIR/twebproxy-nfqws"
  DPI_NFQWS_SUM_FILE="$LIBEXEC_DIR/twebproxy-nfqws.sha256"
}

reset_world() {
  rm -rf "$DPI_DIR" "$SYSTEMD_DIR" "$TMP/libexec" "$TMP/libexec-real" "$TMP/libexec-link" \
         "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  mkdir -p "$SYSTEMD_DIR" "$TMP/libexec" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  rm -f "$MOCK_NFT_LIVE"; : > "$SYSTEMCTL_LOG"; : > "$SYSTEMCTL_TRACE"
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  use_libexec "$TMP/libexec"
  CURRENT_LOG="$TMP/manager-transcript.log"; : > "$CURRENT_LOG"; chmod 0600 "$CURRENT_LOG"
}

# --- the two forcing modes, both real conditions the guard exists for ---------
# A: something that is not a regular file occupies the owned binary's path.
force_dir_at_owned_binary() { mkdir -p "$DPI_NFQWS_BIN"; }
# B: a symlinked libexec parent, which dpi_nfqws_runtime_parent_safe refuses.
force_symlinked_libexec_parent() {
  mkdir -p "$TMP/libexec-real"
  ln -sfn "$TMP/libexec-real" "$TMP/libexec-link"
  use_libexec "$TMP/libexec-link"
}

seed_window1152_state() {
  install -d -m 0700 "$DPI_DIR" "$DPI_STATE_DIR"
  dpi_write_scope_state "$DPI_STATE_DIR" "$SCOPE_IP" window1152 alpha.example
}

printf '\n--- 0. the forcing modes really trip the guard ---\n'
reset_world; force_dir_at_owned_binary
dpi_remove_owned_nfqws_runtime_files; rc=$?
check_nonzero A0_dir_at_owned_binary_is_refused "$rc"
reset_world; force_symlinked_libexec_parent
dpi_remove_owned_nfqws_runtime_files; rc=$?
check_nonzero B0_symlinked_libexec_parent_is_refused "$rc"

for mode in dir symlink; do
  case "$mode" in
    dir)     force=force_dir_at_owned_binary; P=A;;
    symlink) force=force_symlinked_libexec_parent; P=B;;
  esac

  printf '\n--- %s. forcing mode: %s ---\n' "$P" "$mode"

  # 1. the leaf failure propagates out of dpi_cleanup_nfqws_runtime
  reset_world; "$force"
  dpi_cleanup_nfqws_runtime; rc=$?
  check_nonzero "${P}1_cleanup_nfqws_runtime_propagates" "$rc"

  # 2. and out of the STOCK cleanup: STOCK must stay fail-closed
  reset_world; "$force"
  dpi_cleanup_stock_runtime; rc=$?
  check_nonzero "${P}2_cleanup_stock_runtime_propagates" "$rc"

  # 3. the per-unit systemd teardown is NOT weakened: it runs before the file
  #    removal, so the nfqws unit is still stopped and its unit file removed.
  reset_world; "$force"
  systemctl_model_seed_unit "$DPI_NFQWS_UNIT" 1 1
  systemctl_model_seed_unit "$DPI_FIREWALL_UNIT" 1 1
  dpi_cleanup_stock_runtime >/dev/null 2>&1
  check_not "${P}3_nfqws_unit_stopped_anyway" systemctl is-active --quiet "$DPI_NFQWS_UNIT"
  check_not "${P}3_nfqws_unit_file_removed_anyway" test -e "$SYSTEMD_DIR/$DPI_NFQWS_UNIT"
  check_not "${P}3_firewall_unit_stopped_anyway" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"

  # 4. reconciliation to STOCK (empty scope state) must fail, not report success
  reset_world; "$force"
  install -d -m 0700 "$DPI_DIR" "$DPI_STATE_DIR"
  dpi_reconcile_runtime >/dev/null 2>&1; rc=$?
  check_nonzero "${P}4_reconcile_to_stock_fails" "$rc"

  # 5. reconciliation of a non-nfqws mode also runs the nfqws cleanup stage
  reset_world; "$force"; seed_window1152_state
  dpi_reconcile_runtime >/dev/null 2>&1; rc=$?
  check_nonzero "${P}5_reconcile_non_nfqws_mode_fails" "$rc"

  # 6. the caller never sees success, and the transcript is not contradictory
  reset_world; "$force"
  dpi_transaction_set "$SCOPE_IP" window1152 alpha.example >/dev/null 2>&1; rc=$?
  check_nonzero "${P}6_transaction_does_not_report_success" "$rc"
  check_not "${P}6_no_state_committed" test -e "$DPI_STATE_DIR/$SCOPE_IP.env"
  if grep -Fq 'result=failed' "$CURRENT_LOG" && (( rc == 0 )); then
    t_bad "${P}6_no_failed_record_with_successful_transaction"
  else
    t_ok "${P}6_no_failed_record_with_successful_transaction"
  fi

  # 7. diagnostics still name the cleanup stage and give a reason
  check "${P}7_transcript_names_cleanup_stage" grep -Fq 'stage=cleanup nfqws runtime' "$CURRENT_LOG"
  check "${P}7_transcript_has_reason" grep -Eq 'stage=cleanup nfqws runtime .*reason=.' "$CURRENT_LOG"
  check "${P}7_transcript_marks_failed" grep -Eq 'stage=cleanup nfqws runtime .*result=failed' "$CURRENT_LOG"
done

printf '\n--- C. control: an unobstructed system is unaffected ---\n'
reset_world
dpi_cleanup_nfqws_runtime; rc=$?
check_zero C_cleanup_nfqws_runtime_ok_when_unobstructed "$rc"
reset_world
dpi_cleanup_stock_runtime; rc=$?
check_zero C_cleanup_stock_runtime_ok_when_unobstructed "$rc"
reset_world
dpi_transaction_set "$SCOPE_IP" window1152 alpha.example >/dev/null 2>&1; rc=$?
check_zero C_activation_still_succeeds "$rc"
check C_state_committed grep -Fq 'MODE=window1152' "$DPI_STATE_DIR/$SCOPE_IP.env"
check C_firewall_unit_active systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
check_not C_no_failed_record_on_success grep -Fq 'result=failed' "$CURRENT_LOG"

# The owned files are really removed when nothing obstructs them: the guard is
# a refusal path, not the normal path.
reset_world
: > "$DPI_NFQWS_BIN"; : > "$DPI_NFQWS_SUM_FILE"
dpi_cleanup_nfqws_runtime; rc=$?
check_zero C_owned_files_removal_succeeds "$rc"
check_not C_owned_binary_removed test -e "$DPI_NFQWS_BIN"
check_not C_owned_checksum_removed test -e "$DPI_NFQWS_SUM_FILE"

printf '\ndf3b-nfqws-cleanup-propagation: %s pass, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
