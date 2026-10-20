#!/usr/bin/env bash
# Stage A / A2 regression: `twebproxy dpi disable|stock HOST` must reconcile
# manager-owned DPI runtime even when the target owns no state - and must never
# tear down another scope's runtime while doing it.
#
# The 0.2.9 shape was:
#     if [[ ! -f "$(dpi_state_path "$DPI_STATE_DIR" "$ip")" ]]; then
#       ok "$(ui_msgf dpi_disabled "$host")"; return 0
#     fi
# On a real VPS this reported success while twebproxy-dpi-firewall.service was
# still active with no state behind it (the not-found/active ghost): the public
# command said STOCK and left the orphan running.
#
# Every case here is driven through the PUBLIC path - dpi_cmd disable / stock -
# in a subshell, because `die` exits. Assertions are made on the resulting
# filesystem and unit state, which is what the public command exists to change.
#
# Usage: sa2-stock-orphan-reconcile.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check()     { local n="$1"; shift; if "$@"; then t_ok "$n"; else t_bad "$n"; fi; }
check_not() { local n="$1"; shift; if "$@"; then t_bad "$n"; else t_ok "$n"; fi; }

TMP="$(mktemp -d /tmp/sa2-stock.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT

# shellcheck source=/dev/null
source "$ROOT/tests/lib/dpi-harness.sh"
dpi_harness_env "$TMP"
# shellcheck source=/dev/null
source "$MGR"
trap - ERR
set +e
dpi_harness_bind "$ROOT" "$TMP"

A_IP=198.51.100.10; B_IP=198.51.100.20
A_HOST=alpha.example; B_HOST=beta.example
DNS_MODE=ok
getent() {
  [[ "${1:-}" == ahostsv4 ]] || return 2
  [[ "$DNS_MODE" == ok ]] || return 2
  case "${2:-}" in
    "$A_HOST") printf '%s STREAM %s\n' "$A_IP" "$2";;
    "$B_HOST") printf '%s STREAM %s\n' "$B_IP" "$2";;
    *) return 2;;
  esac
}
list_hosts_array() { printf '%s\n%s\n' "$A_HOST" "$B_HOST"; }
instance_exists() { [[ "${1:-}" == "$A_HOST" || "${1:-}" == "$B_HOST" ]]; }
dpi_local_ipv4_addresses() { printf '%s\n' "$A_IP" "$B_IP"; }

# Driving the real public entrypoint; `die` exits, so it runs in a subshell.
cli() { ( dpi_cmd "$@" ) >"$TMP/cli.out" 2>&1; }

reset_world() {
  rm -rf "$DPI_DIR" "$SYSTEMD_DIR" "$LIBEXEC_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  mkdir -p "$SYSTEMD_DIR" "$LIBEXEC_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  rm -f "$MOCK_NFT_LIVE" "$SYSTEMCTL_LOG" "$SYSTEMCTL_TRACE"
  : > "$SYSTEMCTL_LOG"; : > "$SYSTEMCTL_TRACE"
  DNS_MODE=ok
  CURRENT_LOG="$TMP/manager.log"; : > "$CURRENT_LOG"; chmod 0600 "$CURRENT_LOG"
}
# The exact field runtime: firewall unit installed, enabled and ACTIVE, a live
# DPI table, and no scope state behind either of them.
seed_orphan_runtime() {
  install -d -o root -g root -m 0700 "$DPI_DIR" "$DPI_STATE_DIR"
  printf 'table ip twebproxy_dpi {\n  chain out {\n    ip saddr %s counter\n  }\n}\n' "$A_IP" > "$DPI_NFT_FILE"
  command cp "$DPI_NFT_FILE" "$MOCK_NFT_LIVE"
  printf '#!/bin/sh\n' > "$LIBEXEC_DIR/apply-dpi-firewall"; chmod 0755 "$LIBEXEC_DIR/apply-dpi-firewall"
  systemctl_model_seed_unit "$DPI_FIREWALL_UNIT" 1 1
}
live_has() { local l; l="$("$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" 2>/dev/null)"; [[ "$l" == *"$1"* ]]; }
table_absent() { ! "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" >/dev/null 2>&1; }

for sub in disable stock; do
printf '\n===== public subcommand: dpi %s =====\n' "$sub"

# ---------------------------------------------------------------------
# CASE 1: no target state, no other scopes, orphan runtime present
# ---------------------------------------------------------------------
printf '\n--- %s / CASE 1: orphan runtime, nothing else configured ---\n' "$sub"
reset_world; seed_orphan_runtime
check "sa2_${sub}_c1_precondition_orphan_active" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
cli "$sub" "$A_HOST"; rc=$?
if (( rc == 0 )); then t_ok "sa2_${sub}_c1_command_succeeds"
else t_bad "sa2_${sub}_c1_command_succeeds (rc=$rc): $(tail -2 "$TMP/cli.out" | tr '\n' ' ')"; fi
check_not "sa2_${sub}_c1_firewall_unit_inactive" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
check_not "sa2_${sub}_c1_nfqws_unit_inactive"    systemctl is-active --quiet "$DPI_NFQWS_UNIT"
check_not "sa2_${sub}_c1_firewall_unit_file_gone" test -e "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT"
check     "sa2_${sub}_c1_dpi_table_absent" table_absent

# ---------------------------------------------------------------------
# CASE 2: no target state, but ANOTHER valid scope exists
# ---------------------------------------------------------------------
printf '\n--- %s / CASE 2: another valid scope must survive ---\n' "$sub"
reset_world
dpi_transaction_set "$B_IP" window1152 "$B_HOST" >/dev/null 2>&1
check "sa2_${sub}_c2_precondition_other_scope_state" test -f "$DPI_STATE_DIR/$B_IP.env"
check "sa2_${sub}_c2_precondition_other_scope_live" live_has "$B_IP"
check "sa2_${sub}_c2_precondition_unit_active" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
cli "$sub" "$A_HOST"; rc=$?
if (( rc == 0 )); then t_ok "sa2_${sub}_c2_command_succeeds"
else t_bad "sa2_${sub}_c2_command_succeeds (rc=$rc): $(tail -2 "$TMP/cli.out" | tr '\n' ' ')"; fi
check "sa2_${sub}_c2_other_scope_state_survives" test -f "$DPI_STATE_DIR/$B_IP.env"
check "sa2_${sub}_c2_other_scope_rule_still_live" live_has "$B_IP"
check "sa2_${sub}_c2_other_scope_unit_still_active" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
check "sa2_${sub}_c2_other_scope_unit_file_present" test -f "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT"
check_not "sa2_${sub}_c2_target_owns_no_state" test -f "$DPI_STATE_DIR/$A_IP.env"

# ---------------------------------------------------------------------
# CASE 3: idempotent
# ---------------------------------------------------------------------
printf '\n--- %s / CASE 3: idempotence ---\n' "$sub"
reset_world; seed_orphan_runtime
cli "$sub" "$A_HOST"; cli "$sub" "$A_HOST"; rc=$?
if (( rc == 0 )); then t_ok "sa2_${sub}_c3_second_run_succeeds"
else t_bad "sa2_${sub}_c3_second_run_succeeds (rc=$rc)"; fi
check_not "sa2_${sub}_c3_still_inactive" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"

# ---------------------------------------------------------------------
# CASE 4: unrelated units are never touched
# ---------------------------------------------------------------------
printf '\n--- %s / CASE 4: multi-scope safety, unrelated units ---\n' "$sub"
reset_world; seed_orphan_runtime
systemctl_model_seed_unit twebproxy-firewall.service 1 1
systemctl_model_seed_unit nginx.service 1 1
cli "$sub" "$A_HOST"
# Snapshot before this harness makes its own systemctl calls.
command cp "$SYSTEMCTL_TRACE" "$TMP/trace-c4.log"
check "sa2_${sub}_c4_backend_firewall_untouched" systemctl is-active --quiet twebproxy-firewall.service
check "sa2_${sub}_c4_nginx_untouched" systemctl is-active --quiet nginx.service
foreign="$(awk -F'|' -v a="$DPI_FIREWALL_UNIT" -v b="$DPI_NFQWS_UNIT" \
  '$2 != "" && $2 != a && $2 != b {print $2}' "$TMP/trace-c4.log" | sort -u | wc -l)"
if [[ "$foreign" == 0 ]]; then t_ok "sa2_${sub}_c4_no_foreign_unit_in_calls"
else t_bad "sa2_${sub}_c4_no_foreign_unit_in_calls (got $foreign)"; fi

# ---------------------------------------------------------------------
# CASE 5: a host that never used DPI on a system that never used DPI
# ---------------------------------------------------------------------
printf '\n--- %s / CASE 5: pristine system ---\n' "$sub"
reset_world
cli "$sub" "$A_HOST"; rc=$?
if (( rc == 0 )); then t_ok "sa2_${sub}_c5_pristine_succeeds"
else t_bad "sa2_${sub}_c5_pristine_succeeds (rc=$rc): $(tail -2 "$TMP/cli.out" | tr '\n' ' ')"; fi
check_not "sa2_${sub}_c5_no_dpi_units_activated" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
check "sa2_${sub}_c5_no_dpi_table" table_absent

# ---------------------------------------------------------------------
# CASE 6: control - a real scope is still disabled properly
# ---------------------------------------------------------------------
printf '\n--- %s / CASE 6: control, a configured scope ---\n' "$sub"
reset_world
dpi_transaction_set "$A_IP" window1152 "$A_HOST" >/dev/null 2>&1
cli "$sub" "$A_HOST"; rc=$?
if (( rc == 0 )); then t_ok "sa2_${sub}_c6_command_succeeds"
else t_bad "sa2_${sub}_c6_command_succeeds (rc=$rc)"; fi
check_not "sa2_${sub}_c6_state_removed" test -f "$DPI_STATE_DIR/$A_IP.env"
check_not "sa2_${sub}_c6_unit_inactive" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
check "sa2_${sub}_c6_table_absent" table_absent

# ---------------------------------------------------------------------
# CASE 6b: the host's public address changed since the scope was set
# ---------------------------------------------------------------------
# The commonest way a scope goes stale. DNS now answers a DIFFERENT address, so
# looking up state only by the resolved address finds nothing, and the command
# used to report STOCK while the old rule stayed live.
printf '\n--- %s / CASE 6b: host address changed ---\n' "$sub"
reset_world
dpi_transaction_set "$A_IP" window1152 "$A_HOST" >/dev/null 2>&1
check "sa2_${sub}_c6b_precondition_state" test -f "$DPI_STATE_DIR/$A_IP.env"
check "sa2_${sub}_c6b_precondition_live" live_has "$A_IP"
A_MOVED=198.51.100.77
getent() {
  [[ "${1:-}" == ahostsv4 ]] || return 2
  [[ "$DNS_MODE" == ok ]] || return 2
  case "${2:-}" in
    "$A_HOST") printf '%s STREAM %s\n' "$A_MOVED" "$2";;
    "$B_HOST") printf '%s STREAM %s\n' "$B_IP" "$2";;
    *) return 2;;
  esac
}
dpi_local_ipv4_addresses() { printf '%s\n%s\n%s\n' "$A_IP" "$B_IP" "$A_MOVED"; }
cli "$sub" "$A_HOST"; rc=$?
if (( rc == 0 )); then t_ok "sa2_${sub}_c6b_command_succeeds"
else t_bad "sa2_${sub}_c6b_command_succeeds (rc=$rc): $(tail -2 "$TMP/cli.out" | tr '\n' ' ')"; fi
check_not "sa2_${sub}_c6b_stale_scope_removed" test -f "$DPI_STATE_DIR/$A_IP.env"
check_not "sa2_${sub}_c6b_stale_rule_not_live" live_has "$A_IP"
check_not "sa2_${sub}_c6b_unit_inactive" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
getent() {
  [[ "${1:-}" == ahostsv4 ]] || return 2
  [[ "$DNS_MODE" == ok ]] || return 2
  case "${2:-}" in
    "$A_HOST") printf '%s STREAM %s\n' "$A_IP" "$2";;
    "$B_HOST") printf '%s STREAM %s\n' "$B_IP" "$2";;
    *) return 2;;
  esac
}
dpi_local_ipv4_addresses() { printf '%s\n%s\n' "$A_IP" "$B_IP"; }

# ---------------------------------------------------------------------
# CASE 7: orphan runtime while the resolver is down
# ---------------------------------------------------------------------
printf '\n--- %s / CASE 7: orphan runtime + broken resolver ---\n' "$sub"
reset_world; seed_orphan_runtime; DNS_MODE=broken
cli "$sub" "$A_HOST"; rc=$?
if (( rc == 0 )); then t_ok "sa2_${sub}_c7_command_succeeds_without_dns"
else t_bad "sa2_${sub}_c7_command_succeeds_without_dns (rc=$rc): $(tail -2 "$TMP/cli.out" | tr '\n' ' ')"; fi
check_not "sa2_${sub}_c7_orphan_cleaned_without_dns" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"

# ---------------------------------------------------------------------
# CASE 8: broken resolver must not tear down another live scope
# ---------------------------------------------------------------------
printf '\n--- %s / CASE 8: broken resolver + another live scope ---\n' "$sub"
reset_world
dpi_transaction_set "$B_IP" window1152 "$B_HOST" >/dev/null 2>&1
DNS_MODE=broken
cli "$sub" "$A_HOST"
check "sa2_${sub}_c8_other_scope_state_survives" test -f "$DPI_STATE_DIR/$B_IP.env"
check "sa2_${sub}_c8_other_scope_rule_still_live" live_has "$B_IP"
check "sa2_${sub}_c8_other_scope_unit_still_active" systemctl is-active --quiet "$DPI_FIREWALL_UNIT"
done

printf '\nsa2-stock-orphan-reconcile: %s pass, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
