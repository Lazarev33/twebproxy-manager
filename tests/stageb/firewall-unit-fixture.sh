#!/usr/bin/env bash
# Generated backend firewall unit contract (Stage B + B.1 R1, revised in
# v0.2.23 for P1-EXPOSURE-01 / P1-STOP-01: owned guard session, no PartOf,
# backends BindsTo= + WantedBy= the firewall unit).
# R1: nftables.service ExecReload re-reads /etc/nftables.conf, which by default
# starts with `flush ruleset`; PartOf= propagates only stop/restart, so the
# backend table vanished on `systemctl reload nftables`. ReloadPropagatedFrom=
# queues our idempotent ExecReload after it. Static contract only: the real
# systemd behaviour is a disposable-VM check (tests/LAB.md).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-stageb-unit.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stageb/backend-harness.sh"
backend_harness
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
unit="$SYSTEMD_DIR/twebproxy-firewall.service"
has() { grep -qxF -- "$1" "$unit"; }
count() { grep -c -- "^$1=" "$unit"; }

check unit_written write_backend_firewall_unit
check unit_mode_0644 test "$(stat -c '%a' "$unit")" = 644
check unit_after_nftables has 'After=nftables.service'
# v0.2.23 (P1-STOP-01): no stop/restart cascade from nftables.service.
check unit_not_partof_nftables test "$(count PartOf)" = 0
check unit_reload_propagated_from_nftables has 'ReloadPropagatedFrom=nftables.service'
# v0.2.23 (P1-EXPOSURE-01): the owned guard session is the service itself.
check unit_type_exec has 'Type=exec'
check unit_execstart_guard has "ExecStart=$LIBEXEC_DIR/firewall-guard hold"
check unit_single_execstart test "$(count ExecStart)" = 1
check unit_startpost_guard_wait has "ExecStartPost=$LIBEXEC_DIR/firewall-guard wait"
check unit_startpost_backend_helper has "ExecStartPost=$LIBEXEC_DIR/apply-firewall"
check unit_reload_guard has "ExecReload=$LIBEXEC_DIR/firewall-guard reload \$MAINPID"
check unit_reload_backend_helper has "ExecReload=$LIBEXEC_DIR/apply-firewall"
check unit_no_destructive_stop test "$(count ExecStop)$(count ExecStopPost)" = 00
check unit_restart_on_failure has 'Restart=on-failure'
check unit_timeout_present has 'TimeoutStartSec=240'
templates() { (write_systemd_templates) > "$TMP/templates.out" 2>&1; }
check templates_written templates
relay="$SYSTEMD_DIR/twebproxy@.service"; backend="$SYSTEMD_DIR/twebproxy-mtproxy@.service"
check relay_after_firewall grep -qE '^After=.*twebproxy-firewall\.service' "$relay"
check relay_not_bound_to_firewall bash -c '! grep -qE "^(Requires|BindsTo)=twebproxy-firewall" "$1"' _ "$relay"
check backend_bindsto_firewall grep -qxF 'BindsTo=twebproxy-firewall.service' "$backend"
check backend_after_firewall grep -qE '^After=.*twebproxy-firewall\.service' "$backend"
check backend_wantedby_firewall grep -qxF 'WantedBy=multi-user.target twebproxy-firewall.service' "$backend"
check backend_runs_as_mtproxy grep -qxF 'User=mtproxy' "$backend"
check guard_helper_written write_firewall_guard_helper
check guard_helper_syntax bash -n "$LIBEXEC_DIR/firewall-guard"
check guard_helper_owner_flag grep -qF 'flags owner' "$LIBEXEC_DIR/firewall-guard"
dropin="$SYSTEMD_DIR/nftables.service.d/twebproxy-reassert.conf"
check dropin_written write_nftables_dropin
check dropin_unsandboxed_reapply grep -qxF "ExecStartPost=-+$LIBEXEC_DIR/apply-firewall" "$dropin"
check dropin_reapply_after_stop grep -qxF "ExecStopPost=-+$LIBEXEC_DIR/apply-firewall" "$dropin"

printf 'stageb-firewall-unit: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
