#!/usr/bin/env bash
# DF-3 regression: DPI STOCK/rollback cleanup and stage diagnostics.
#
# Field evidence (v0.2.8-dpi-beta-fielddiag2, window1152 activation failure):
#   systemctl status twebproxy-dpi-firewall.service
#     Loaded: not-found (Reason: Unit twebproxy-dpi-firewall.service not found.)
#     Active: active (exited)
#   systemctl is-active  -> active (rc 0)
#   systemctl is-enabled -> not-found (rc 4)
# i.e. rollback to STOCK removed the unit FILE while the unit was still ACTIVE.
#
# Root cause under test: dpi_cleanup_stock_runtime passed BOTH unit names to a
# single `systemctl disable --now A B`. systemd validates every named unit file
# up front and fails the whole call when one is missing - which is always the
# case for the non-nfqws modes, where the nfqws unit was never installed. The
# `|| true` swallowed that failure, the firewall unit was never stopped, and the
# unit file was then deleted underneath the running unit.
#
# Also covered: precise per-stage diagnostics for DPI activation/reconciliation,
# and the user-facing failure line naming the failed stage.
#
# systemd is not PID 1 in the audit container, so unit lifecycle is exercised
# against tests/lib/systemctl-model.sh. The ordering assertions
# (per-unit invocation, stop issued while the unit file still exists) are
# model-independent: they read the call trace, not the model's own state.
#
# Usage: df3-dpi-cleanup-stage-diagnostics.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local n="$1"; shift; if "$@"; then t_ok "$n"; else t_bad "$n"; fi; }
check_not() { local n="$1"; shift; if "$@"; then t_bad "$n"; else t_ok "$n"; fi; }
check_eq() { local n="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then t_ok "$n"; else t_bad "$n (got '$got', want '$want')"; fi; }

TMP="$(mktemp -d /tmp/df3-dpi-cleanup.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT

export TWEBPROXY_NO_LOG=1
export TWEBPROXY_UI_LANGUAGE=en
export TWEBPROXY_LANGUAGE_FILE="$TMP/ui-language"
export TWEBPROXY_DPI_DIR="$TMP/etc/dpi"
export TWEBPROXY_DPI_NFQWS_BIN="$TMP/libexec/twebproxy-nfqws"
export TWEBPROXY_DPI_NFQWS_SUM_FILE="$TMP/libexec/twebproxy-nfqws.sha256"
export TWEBPROXY_DPI_NFQWS_SOURCE="$ROOT/assets/nfqws-linux-x86_64"
export TWEBPROXY_DPI_DOC_DIR="$TMP/doc"
export TWEBPROXY_NFT_BIN="$TMP/bin/nft"

mkdir -p "$TMP/bin" "$TMP/systemd" "$TMP/libexec" "$TMP/doc"
cat > "$TMP/bin/nft" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
live="${MOCK_NFT_LIVE:?}"
if [[ "${1:-}" == -c && "${2:-}" == -f ]]; then grep -q '^table ip twebproxy_dpi {' "$3"
elif [[ "${1:-}" == -f ]]; then cp "$2" "$live"
elif [[ "${1:-}" == list ]]; then [[ -s "$live" ]] || exit 1; cat "$live"
elif [[ "${1:-}" == delete ]]; then rm -f "$live"
else exit 2; fi
MOCK
chmod 0755 "$TMP/bin/nft"
export MOCK_NFT_LIVE="$TMP/live.nft"

# shellcheck source=/dev/null
source "$MGR"
# The manager sets `set -Eeuo pipefail` when sourced. This harness inspects
# return codes explicitly, so -e must not abort it on a deliberate failure.
trap - ERR
set +e

BASE_DIR="$TMP/etc"; INSTANCES_DIR="$TMP/instances"
DPI_DIR="$TWEBPROXY_DPI_DIR"; DPI_STATE_DIR="$DPI_DIR/scopes"
DPI_NFT_FILE="$DPI_DIR/firewall.nft"
DPI_NFT_BIN="$TMP/bin/nft"
DPI_NFQWS_BIN="$TWEBPROXY_DPI_NFQWS_BIN"
DPI_NFQWS_SUM_FILE="$TWEBPROXY_DPI_NFQWS_SUM_FILE"
DPI_DOC_DIR="$TMP/doc"
LIBEXEC_DIR="$TMP/libexec"; SYSTEMD_DIR="$TMP/systemd"
DPI_FIREWALL_UNIT=twebproxy-dpi-firewall.service
DPI_NFQWS_UNIT=twebproxy-dpi-nfqws.service
UI_LANGUAGE=en
mkdir -p "$INSTANCES_DIR"

SYSTEMCTL_ACTIVE_DIR="$TMP/systemctl-active"
SYSTEMCTL_LOG="$TMP/systemctl.log"
SYSTEMCTL_TRACE="$TMP/systemctl-trace.log"
# shellcheck source=/dev/null
source "$ROOT/tests/lib/systemctl-model.sh"

id() { [[ "${1:-}" == twebproxy-dpi ]] && return 0; command id "$@"; }
useradd() { return 0; }
userdel() { return 0; }
# Same seam the existing DPI fixtures use: the scope gate (TWP-003) is not the
# subject here, tests/fieldgate/tg5-* covers it against the real probe.
dpi_local_ipv4_addresses() { printf '%s\n' 198.51.100.10; }
getent() {
  case "$1:${2:-}" in
    ahostsv4:alpha.example) printf '198.51.100.10 STREAM alpha.example\n';;
    *) return 2;;
  esac
}
instance_exists() { [[ "${1:-}" == alpha.example ]]; }
dpi_hosts_for_ipv4() { [[ "${1:-}" == 198.51.100.10 ]] && printf 'alpha.example\n'; return 0; }

SCOPE_IP=198.51.100.10

reset_world() {
  rm -rf "$DPI_DIR" "$SYSTEMD_DIR" "$LIBEXEC_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  mkdir -p "$SYSTEMD_DIR" "$LIBEXEC_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  rm -f "$MOCK_NFT_LIVE" "$SYSTEMCTL_LOG" "$SYSTEMCTL_TRACE" "$DPI_NFQWS_BIN" "$DPI_NFQWS_SUM_FILE"
  : > "$SYSTEMCTL_LOG"; : > "$SYSTEMCTL_TRACE"
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  CURRENT_LOG="$TMP/manager-transcript.log"; : > "$CURRENT_LOG"; chmod 0600 "$CURRENT_LOG"
}

# Reproduces the exact runtime the field failure left behind for a non-nfqws
# mode: the firewall unit installed, enabled and active; no nfqws unit file.
seed_active_firewall() {
  install -d -m 0700 "$DPI_DIR" "$DPI_STATE_DIR"
  printf 'table ip twebproxy_dpi {\n}\n' > "$DPI_NFT_FILE"
  cp "$DPI_NFT_FILE" "$MOCK_NFT_LIVE"
  printf '#!/bin/sh\n' > "$LIBEXEC_DIR/apply-dpi-firewall"; chmod 0755 "$LIBEXEC_DIR/apply-dpi-firewall"
  systemctl_model_seed_unit "$DPI_FIREWALL_UNIT" 1 1
}

trace_has() { grep -Fq "$1" "${2:-$SYSTEMCTL_TRACE}"; }

printf '\n--- A. STOCK cleanup leaves no active DPI firewall runtime state ---\n'
reset_world; seed_active_firewall
dpi_cleanup_stock_runtime; A_RC=$?
# Snapshot the call trace before this harness makes its own systemctl calls.
cp "$SYSTEMCTL_TRACE" "$TMP/trace-A.log"
check_eq A_cleanup_returns_success "$A_RC" 0
check_not A_firewall_not_active systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
check_not A_unit_file_removed test -e "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT"
systemctl is-enabled "$DPI_FIREWALL_UNIT" >/dev/null 2>&1; A_EN=$?
check_eq A_is_enabled_reports_not_found "$A_EN" 4
check_not A_nft_table_removed test -s "$MOCK_NFT_LIVE"
check_not A_helper_removed test -e "$LIBEXEC_DIR/apply-dpi-firewall"

# Model-independent ordering: the firewall unit must be stopped while its unit
# file is still present, and never named in a call together with another unit.
check A_stop_issued_before_unit_file_removed trace_has "stop|$DPI_FIREWALL_UNIT|unitfile=yes" "$TMP/trace-A.log"
MULTI="$(awk -F'|' '$4 != "units=1" {print}' "$TMP/trace-A.log" | wc -l)"
check_eq A_no_multi_unit_systemctl_call "$MULTI" 0

printf '\n--- B. Cleanup is idempotent ---\n'
dpi_cleanup_stock_runtime; B1=$?
dpi_cleanup_stock_runtime; B2=$?
check_eq B_second_cleanup_ok "$B1" 0
check_eq B_third_cleanup_ok "$B2" 0
check_not B_still_not_active systemctl is-active --quiet "$DPI_FIREWALL_UNIT"

printf '\n--- C. An already-ghosted unit (file gone, still active) is repaired ---\n'
reset_world; seed_active_firewall
# Exactly the field state: unit file deleted while the unit is still active.
rm -f "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT"
check C_precondition_ghost_active systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
dpi_cleanup_stock_runtime; C_RC=$?
check_eq C_cleanup_returns_success "$C_RC" 0
check_not C_ghost_cleared systemctl is-active --quiet "$DPI_FIREWALL_UNIT"

printf '\n--- D. Unrelated systemd units are never touched ---\n'
reset_world; seed_active_firewall
systemctl_model_seed_unit twebproxy-firewall.service 1 1
systemctl_model_seed_unit nginx.service 1 1
dpi_cleanup_stock_runtime >/dev/null 2>&1
cp "$SYSTEMCTL_TRACE" "$TMP/trace-D.log"
check D_backend_firewall_still_active systemctl is-active --quiet twebproxy-firewall.service
check D_nginx_still_active systemctl is-active --quiet nginx.service
check D_backend_firewall_still_enabled systemctl_model_is_enabled twebproxy-firewall.service
FOREIGN="$(awk -F'|' -v a="$DPI_FIREWALL_UNIT" -v b="$DPI_NFQWS_UNIT" \
  '$2 != "" && $2 != a && $2 != b {print $2}' "$TMP/trace-D.log" | sort -u | wc -l)"
check_eq D_no_foreign_unit_in_calls "$FOREIGN" 0

printf '\n--- E. Normal STOCK disable leaves the service non-active ---\n'
reset_world
dpi_transaction_set "$SCOPE_IP" window1152 alpha.example; E_SET=$?
check_eq E_activation_succeeds "$E_SET" 0
check E_firewall_active_after_set systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
dpi_transaction_disable_ip "$SCOPE_IP"; E_DIS=$?
check_eq E_disable_succeeds "$E_DIS" 0
check_not E_state_removed test -e "$DPI_STATE_DIR/$SCOPE_IP.env"
check_not E_firewall_not_active_after_disable systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
check_not E_unit_file_removed_after_disable test -e "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT"

printf '\n--- F. Failed activation from STOCK rolls back to a clean STOCK ---\n'
for stage in 'restart unit' 'cleanup nfqws runtime' 'verify runtime' 'commit state'; do
  reset_world
  export TWEBPROXY_DPI_TEST_FAIL_POINT="stage:$stage"
  dpi_transaction_set "$SCOPE_IP" window1152 alpha.example; F_RC=$?
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  label="$(printf '%s' "$stage" | tr ' ' '_')"
  if (( F_RC == 0 )); then t_bad "F_${label}_transaction_must_fail"; else t_ok "F_${label}_transaction_fails"; fi
  check_not "F_${label}_no_active_firewall" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
  check_not "F_${label}_no_active_nfqws" systemctl is-active --quiet "$DPI_NFQWS_UNIT"
  check_not "F_${label}_no_state_committed" test -e "$DPI_STATE_DIR/$SCOPE_IP.env"
  check_not "F_${label}_no_live_dpi_table" test -s "$MOCK_NFT_LIVE"
  # The transcript must name the exact failed stage and the rollback result.
  check "F_${label}_transcript_names_stage" grep -Fq "stage=$stage" "$CURRENT_LOG"
  check "F_${label}_transcript_result_failed" grep -Fq "result=failed" "$CURRENT_LOG"
  check "F_${label}_transcript_reports_rollback" grep -Fq "rollback=" "$CURRENT_LOG"
  check_eq "F_${label}_last_stage_recorded" "${DPI_LAST_STAGE:-}" "$stage"
done

printf '\n--- G. Rollback restores the previous DPI mode and runtime ---\n'
reset_world
dpi_transaction_set "$SCOPE_IP" window1152 alpha.example >/dev/null 2>&1
G_BEFORE="$(cat "$MOCK_NFT_LIVE" 2>/dev/null)"
for stage in 'restart unit' 'verify runtime' 'commit state'; do
  export TWEBPROXY_DPI_TEST_FAIL_POINT="stage:$stage"
  dpi_transaction_set "$SCOPE_IP" mss88 alpha.example >/dev/null 2>&1; G_RC=$?
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  label="$(printf '%s' "$stage" | tr ' ' '_')"
  if (( G_RC == 0 )); then t_bad "G_${label}_must_fail"; else t_ok "G_${label}_fails"; fi
  check "G_${label}_previous_mode_kept" grep -Fq 'MODE=window1152' "$DPI_STATE_DIR/$SCOPE_IP.env"
  check "G_${label}_previous_rules_restored" test "$(cat "$MOCK_NFT_LIVE" 2>/dev/null)" = "$G_BEFORE"
  check "G_${label}_firewall_active_again" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
done

printf '\n--- H. Every reconciliation stage is individually attributable ---\n'
STAGES=(
  'prepare runtime' 'render rules' 'write firewall unit' 'daemon-reload'
  'enable unit' 'apply nft candidate' 'restart unit' 'cleanup nfqws runtime'
  'verify runtime'
)
for stage in "${STAGES[@]}"; do
  reset_world
  export TWEBPROXY_DPI_TEST_FAIL_POINT="stage:$stage"
  dpi_transaction_set "$SCOPE_IP" window1152 alpha.example >/dev/null 2>&1; H_RC=$?
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  label="$(printf '%s' "$stage" | tr ' ' '_')"
  if (( H_RC == 0 )); then t_bad "H_${label}_must_fail"; else t_ok "H_${label}_fails"; fi
  check_eq "H_${label}_stage_recorded" "${DPI_LAST_STAGE:-}" "$stage"
  check "H_${label}_transcript_line" grep -Fq "stage=$stage" "$CURRENT_LOG"
  check "H_${label}_transcript_has_status" grep -Eq "stage=$stage .*status=[0-9]+ result=failed" "$CURRENT_LOG"
  check "H_${label}_transcript_has_op" grep -Eq "stage=$stage op=[^ ]+" "$CURRENT_LOG"
  check "H_${label}_transcript_has_reason" grep -Eq "stage=$stage .*reason=." "$CURRENT_LOG"
done

printf '\n--- H2. nfqws-only stages are attributable too ---\n'
for stage in 'install nfqws runtime' 'write nfqws unit' 'enable nfqws unit'; do
  reset_world
  export TWEBPROXY_DPI_TEST_FAIL_POINT="stage:$stage"
  dpi_transaction_set "$SCOPE_IP" nfqws alpha.example >/dev/null 2>&1; H2_RC=$?
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  label="$(printf '%s' "$stage" | tr ' ' '_')"
  if (( H2_RC == 0 )); then t_bad "H2_${label}_must_fail"; else t_ok "H2_${label}_fails"; fi
  check_eq "H2_${label}_stage_recorded" "${DPI_LAST_STAGE:-}" "$stage"
  check "H2_${label}_transcript_line" grep -Fq "stage=$stage" "$CURRENT_LOG"
  check_not "H2_${label}_no_active_nfqws" systemctl is-active --quiet "$DPI_NFQWS_UNIT"
done

printf '\n--- I. Legacy forced-failure points still behave as before ---\n'
for point in after_firewall nfqws_start after_state; do
  reset_world
  export TWEBPROXY_DPI_TEST_FAIL_POINT="$point"
  mode=window1152; [[ "$point" == nfqws_start ]] && mode=nfqws
  dpi_transaction_set "$SCOPE_IP" "$mode" alpha.example >/dev/null 2>&1; I_RC=$?
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  if (( I_RC == 0 )); then t_bad "I_${point}_must_fail"; else t_ok "I_${point}_fails"; fi
  check_not "I_${point}_no_state" test -e "$DPI_STATE_DIR/$SCOPE_IP.env"
  check_not "I_${point}_no_active_firewall" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
done

printf '\n--- I2. Legacy points and pre-commit refusals are attributable too ---\n'
reset_world
export TWEBPROXY_DPI_TEST_FAIL_POINT=after_firewall
dpi_transaction_set "$SCOPE_IP" window1152 alpha.example >/dev/null 2>&1
unset TWEBPROXY_DPI_TEST_FAIL_POINT
# after_firewall aborts between "apply nft candidate" and the restart, so the
# stage it prevents is the one reported - never a stage that actually succeeded.
check_eq I2_after_firewall_names_prevented_stage "${DPI_LAST_STAGE:-}" 'restart unit'

reset_world
SAVED_NFT="$DPI_NFT_BIN"; DPI_NFT_BIN="$TMP/bin/nft-missing"
dpi_transaction_set "$SCOPE_IP" window1152 alpha.example >/dev/null 2>&1; I2_RC=$?
DPI_NFT_BIN="$SAVED_NFT"
if (( I2_RC == 0 )); then t_bad I2_candidate_check_must_fail; else t_ok I2_candidate_check_fails; fi
check_eq I2_candidate_stage_recorded "${DPI_LAST_STAGE:-}" 'check nft candidate'
check_not I2_candidate_refusal_commits_nothing test -e "$DPI_STATE_DIR/$SCOPE_IP.env"

# A nested helper may record its own sub-stage; the stage reported to the
# operator must still be the stage that was actually being run.
reset_world
dpi_transaction_set "$SCOPE_IP" window1152 alpha.example >/dev/null 2>&1
DF3_SAVED_TEARDOWN="$(declare -f dpi_unit_teardown)"
dpi_unit_teardown() { dpi_stage_fail 'cleanup unit runtime' inner 1 'nested sub-stage'; return 1; }
dpi_reconcile_runtime >/dev/null 2>&1; I2_REC=$?
eval "$DF3_SAVED_TEARDOWN"          # restore the production function verbatim
if (( I2_REC == 0 )); then t_bad I2_nested_failure_must_fail; else t_ok I2_nested_failure_fails; fi
check_eq I2_outer_stage_wins "${DPI_LAST_STAGE:-}" 'cleanup nfqws runtime'

printf '\n--- J. Failure line names the stage; TUI stays concise ---\n'
reset_world
DPI_LAST_STAGE='verify runtime'
UI_LANGUAGE=en
MSG_EN="$(dpi_transaction_failure_message window1152)"
UI_LANGUAGE=ru
MSG_RU="$(dpi_transaction_failure_message window1152)"
UI_LANGUAGE=en
check J_message_key_defined test "$MSG_EN" != dpi_transaction_failed_stage
check J_message_names_stage grep -Fq 'verify runtime' <<< "$MSG_EN"
check J_message_names_mode grep -Fq 'window1152' <<< "$MSG_EN"
check J_message_ru_localized grep -Fq 'этап: verify runtime' <<< "$MSG_RU"
check J_message_ru_names_mode grep -Fq 'window1152' <<< "$MSG_RU"
check_eq J_message_is_single_line "$(printf '%s' "$MSG_EN" | wc -l)" 0
DPI_LAST_STAGE=''
MSG_NOSTAGE="$(dpi_transaction_failure_message window1152)"
check J_falls_back_without_stage test "$MSG_NOSTAGE" = "$(ui_msg dpi_transaction_failed)"

# Detailed diagnostics must go to the transcript, not to the concise TUI.
reset_world
export TWEBPROXY_DPI_TEST_FAIL_POINT='stage:verify runtime'
STDOUT="$(dpi_transaction_set "$SCOPE_IP" window1152 alpha.example 2>/dev/null)"
unset TWEBPROXY_DPI_TEST_FAIL_POINT
check_not J_stage_detail_not_on_stdout grep -Fq 'stage=verify runtime' <<< "$STDOUT"
check J_stage_detail_in_transcript grep -Fq 'stage=verify runtime' "$CURRENT_LOG"

# Diagnostics carry only structured operational fields - no secrets.
BADKEYS="$(grep -o '[A-Za-z_][A-Za-z_-]*=' "$CURRENT_LOG" | sort -u \
  | grep -Ev '^(stage|op|status|result|reason|unit|rollback|phase|mode|scope)=$' | wc -l)"
check_eq J_diagnostics_use_known_fields_only "$BADKEYS" 0
check_not J_no_secret_field grep -Eiq '(secret|password|token|key)=' "$CURRENT_LOG"

printf '\n--- K. Repair-to-STOCK and full uninstall leave no active unit ---\n'
reset_world
dpi_transaction_set "$SCOPE_IP" window1152 alpha.example >/dev/null 2>&1
# Repair with no resolvable host prunes the scope and reconciles back to STOCK.
dpi_hosts_for_ipv4() { return 0; }
dpi_repair_all >/dev/null 2>&1
dpi_hosts_for_ipv4() { [[ "${1:-}" == 198.51.100.10 ]] && printf 'alpha.example\n'; return 0; }
check_not K_repair_leaves_no_active_firewall systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
check_not K_repair_removes_unit_file test -e "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT"

reset_world
dpi_transaction_set "$SCOPE_IP" nfqws alpha.example >/dev/null 2>&1
dpi_full_uninstall >/dev/null 2>&1
check_not K_uninstall_no_active_firewall systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
check_not K_uninstall_no_active_nfqws systemctl is-active --quiet "$DPI_NFQWS_UNIT"
check_not K_uninstall_removes_firewall_unit test -e "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT"
check_not K_uninstall_removes_nfqws_unit test -e "$SYSTEMD_DIR/$DPI_NFQWS_UNIT"
check_not K_uninstall_removes_state test -e "$DPI_DIR"

printf '\ndf3-dpi-cleanup-stage-diagnostics: %s pass, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
