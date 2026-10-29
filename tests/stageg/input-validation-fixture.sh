#!/usr/bin/env bash
# Stage G regression: mutating commands that take a hostname argument validate
# it before the name reaches any path (instance state, state locks, DPI scope,
# certificate and report locations). Names that resolve to an existing
# instance through path tricks ("alpha.example/.", "../instances/alpha.example")
# or differ only in case are refused with the hostname message and change
# nothing. Model harness (Stage E operations harness: systemctl, nft, ip,
# hostnamectl, curl are models); nothing outside $TMP.
#
# dpi disable is exercised through dpi_disable_host_locked: the C1 harness stubs
# the DPI mutation lock wrapper that dpi_disable_cmd goes through.
#
# Usage: input-validation-fixture.sh [path/to/twebproxy-manager.sh]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-g-input.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stagee/ops-harness.sh"
e_harness
export TWEBPROXY_RELAY_READY_WAIT=3
pass=0; fail=0
check() { local name="$1"; shift; if "$@"; then printf 'PASS %s\n' "$name"; pass=$((pass+1)); else printf 'FAIL %s\n' "$name"; fail=$((fail+1)); fi; }
A=alpha.example
install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR"
c2_relay_binary old > "$TPROXY_BIN"; chmod 0755 "$TPROXY_BIN"
d_seed_instance "$A" 18080 18081 nginx-le admin@example.org
c1_seed_profile "$A" main "$(printf '%032d' 1)" https 23980 28980
c1_run rebuild_profiles_json "$A" >/dev/null 2>&1
state() { find "$TMP/etc" "$TMP/units" -printf '%P %m %s\n' 2>/dev/null | LC_ALL=C sort | sha256sum; }

for host in "$A/." "../instances/$A" "$A/../$A" "Alpha.Example"; do
  for cmd in "restart_cmd" "cert_renew_cmd" "dpi_set_cmd:aggressive" "dpi_disable_host_locked" "field_report_cmd:--instant"; do
    fn="${cmd%%:*}"; arg=""; [[ "$cmd" == *:* ]] && arg="${cmd#*:}"
    before="$(state)"
    if [[ -n "$arg" && "$fn" == field_report_cmd ]]; then e_run "$fn" "$arg" "$host" > "$TMP/out" 2>&1
    elif [[ -n "$arg" ]]; then e_run "$fn" "$host" "$arg" > "$TMP/out" 2>&1
    else e_run "$fn" "$host" > "$TMP/out" 2>&1; fi
    rc=$?
    check "g5_${fn}_refuses_[$host] (rc=$rc)" eval "test $rc -ne 0 && grep -q 'lowercase ASCII/ACE hostname' '$TMP/out'"
    check "g5_${fn}_no_state_change_[$host]" test "$(state)" = "$before"
  done
done
# The valid name still works where the model allows it (restart).
e_run restart_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check "g5_restart_valid_host_ok (rc=$rc)" test "$rc" -eq 0

printf 'input-validation-fixture: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
