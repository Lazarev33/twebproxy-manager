#!/usr/bin/env bash
# Model fixture for the v0.2.24 backend start gate (backend_start_check_main),
# the generated helper and the unit contract. No host state is read or changed:
# systemctl and the procfs probe are replaced by functions; the helper is
# generated into a private directory.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d /tmp/twebproxy-start-gate.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT
pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: expected '$3' got '$2'"; fi; }

# $1 deny, $2 bytes, $3 proc (hidden|exposed), $4 policy (on|off|none), $5 unit
gate() {
  ( TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 source "$ROOT/twebproxy-manager.sh"; trap - ERR; set +e
    G_DENY="$1"; G_BYTES="$2"; G_PROC="$3"; PROC_POLICY_FILE="$TMP/policy"
    rm -f "$PROC_POLICY_FILE"; [[ "$4" == none ]] || printf '%s\n' "$4" > "$PROC_POLICY_FILE"
    systemctl() { case "$3" in IPAddressDeny) printf '%s\n' "$G_DENY";; IPIngressBytes) printf '%s\n' "$G_BYTES";; esac; }
    proc_hide_active() { [[ "$G_PROC" == hidden ]]; }
    proc_hidepid_value() { :; }
    backend_start_check_main "$5" ) >"$TMP/out" 2>&1
  echo $?
}
U=twebproxy-mtproxy@example.org--default.service
check enforced-hidden   "$(gate '::/0 0.0.0.0/0' 123 hidden none "$U")" 0
check enforced-zero     "$(gate '0.0.0.0/0 ::/0' 0 hidden none "$U")" 0
check deny-missing      "$(gate '' 123 hidden none "$U")" 1
check deny-v4-only      "$(gate '0.0.0.0/0' 123 hidden none "$U")" 1
check no-bpf            "$(gate '::/0 0.0.0.0/0' '[no data]' hidden none "$U")" 1
check proc-exposed      "$(gate '::/0 0.0.0.0/0' 5 exposed none "$U")" 1
check proc-exposed-on   "$(gate '::/0 0.0.0.0/0' 5 exposed hidepid "$U")" 1
check proc-optout       "$(gate '::/0 0.0.0.0/0' 5 exposed off "$U")" 0
grep -q 'WARNING: procfs hardening disabled by the operator' "$TMP/out"; check optout-warning "$?" 0
check optout-no-filter  "$(gate '' 5 exposed off "$U")" 1
check bad-unit          "$(gate '::/0 0.0.0.0/0' 5 hidden none 'nginx.service')" 1
check bad-unit-path     "$(gate '::/0 0.0.0.0/0' 5 hidden none 'twebproxy-mtproxy@../x.service')" 1

# Generated helper: standalone, syntax-valid, carries the same functions.
( TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 source "$ROOT/twebproxy-manager.sh"; trap - ERR
  LIBEXEC_DIR="$TMP"; write_backend_start_check_helper ) ; check helper-written "$?" 0
bash -n "$TMP/backend-start-check"; check helper-syntax "$?" 0
for f in proc_top_mount_options proc_unprivileged_can_read proc_hide_active backend_start_check_main; do
  grep -q "^$f ()" "$TMP/backend-start-check"; check "helper-has-$f" "$?" 0
done
[[ "$(stat -c %a "$TMP/backend-start-check")" == 755 ]]; check helper-mode "$?" 0

# Unit contract as written by write_systemd_templates (rendered into a private dir).
( TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 source "$ROOT/twebproxy-manager.sh"; trap - ERR
  SYSTEMD_DIR="$TMP"; systemctl() { :; }; write_backend_firewall_unit() { :; }; write_systemd_templates ) >/dev/null 2>&1
u="$TMP/twebproxy-mtproxy@.service"
for line in 'ExecStartPre=+/usr/local/libexec/twebproxy/backend-start-check %n' 'IPAccounting=yes' 'IPAddressDeny=any' \
    'IPAddressAllow=localhost' 'BindsTo=twebproxy-firewall.service'; do
  grep -qxF -- "$line" "$u"; check "unit: $line" "$?" 0
done
grep -q '@TELEGRAM_DC_CIDRS@' "$u"; check unit-placeholder-substituted "$?" 1
grep -qx 'IPAddressAllow=91.108.56.0/22 .* 2a0a:f280::/32' "$u"; check unit-dc-allowlist "$?" 0
(( $(grep -c '^ExecStartPre=' "$u") == 1 )); check unit-one-prestart "$?" 0

echo "start-gate-fixture: pass=$pass fail=$fail"
(( fail == 0 ))
