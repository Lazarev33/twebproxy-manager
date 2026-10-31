#!/usr/bin/env bash
# Generated backend firewall unit contract (Stage B + B.1 R1).
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
check unit_partof_nftables has 'PartOf=nftables.service'
check unit_reload_propagated_from_nftables has 'ReloadPropagatedFrom=nftables.service'
check unit_oneshot has 'Type=oneshot'
check unit_remain_after_exit has 'RemainAfterExit=yes'
check unit_execstart_helper has "ExecStart=$LIBEXEC_DIR/apply-firewall"
check unit_execreload_same_helper has "ExecReload=$LIBEXEC_DIR/apply-firewall"
check unit_no_destructive_stop test "$(count ExecStop)$(count ExecStopPost)" = 00
check unit_single_execstart test "$(count ExecStart)" = 1
# The reload helper fits in the start timeout, which systemd also applies to reload.
check unit_timeout_present has 'TimeoutStartSec=240'
# R2 is documented, not changed in B.1: relay/backend units keep Requires=.
templates() { (write_systemd_templates) > "$TMP/templates.out" 2>&1; }
check templates_written templates
check relay_requires_firewall grep -qxF 'Requires=twebproxy-firewall.service' "$SYSTEMD_DIR/twebproxy@.service"
check backend_requires_firewall grep -qxF 'Requires=twebproxy-firewall.service' "$SYSTEMD_DIR/twebproxy-mtproxy@.service"
check backend_runs_as_mtproxy grep -qxF 'User=mtproxy' "$SYSTEMD_DIR/twebproxy-mtproxy@.service"

printf 'stageb-firewall-unit: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
