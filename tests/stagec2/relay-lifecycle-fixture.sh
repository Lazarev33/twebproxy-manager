#!/usr/bin/env bash
# C2 regression: relay binary update and relay lifecycle operations are
# failure-safe. A failed validation, binary write, restart, readiness check or
# interruption leaves the previous binary installed and every relay running it
# (or reports precisely which relay is not ready); success is reported only
# after every relay is verified on the new binary; relay updates and restarts
# are serialized; instance restart/delete report systemd failures.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-c2-relay.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stagec2/relay-harness.sh"
c2_harness
export TWEBPROXY_RELAY_READY_WAIT=3   # bounded readiness wait, shortened for the model
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
not() { ! "$@"; }
show() { grep -E '\[(x|!|\+)\]' "${1:-$TMP/out}" | tail -n 4 | sed 's/\x1b\[[0-9;]*m//g; s/^/  | /'; }
A=alpha.example; B=beta.example
OLDC=0000000000000000000000000000000000000000 NEWC=1111111111111111111111111111111111111111
PREV="$TMP/opt/relay/tproxy-server.previous"

seed() { # $@ = hosts (default A B), each with one running profile and a running relay
  local h n=0 hosts=("$@"); (( $# )) || hosts=("$A" "$B")
  rm -rf "$INSTANCES_DIR" "$BACKENDS_DIR" "$SITES_DIR" "$BASE_DIR/.locks" "$TMP/opt/relay" "$TMP"/units/* \
    "$TMP"/fail-* "$TMP"/check-fail-* "$TMP"/unready-* "$TMP"/slow-* "$TMP"/crash-* "$TMP"/state-* \
    "$TMP"/*.reached "$TMP"/*.go "$TMP"/*.pid "$TMP/firewall.applied"
  install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR"; install -d -m 0755 "$SITES_DIR"
  c2_relay_binary old > "$TPROXY_BIN"; chmod 0755 "$TPROXY_BIN"
  for h in "${hosts[@]}"; do
    c1_seed_instance "$h" $((18080 + 2*n)) $((18081 + 2*n))
    c1_seed_profile "$h" main "$(printf '%032d' $((n + 1)))" https $((23980 + n)) $((28980 + n))
    c1_run rebuild_profiles_json "$h" >/dev/null 2>&1
    "$TMP/bin/systemctl" start "twebproxy-mtproxy@$h--main.service"
    "$TMP/bin/systemctl" start "twebproxy@$h.service"
    n=$((n + 1))
  done
  printf 'MANAGER_VERSION=0\nTPROXY_UPSTREAM_COMMIT=%s\nMTPROXY_COMMIT=0\n' "$OLDC" > "$GLOBAL_ENV"
  c1_eval rebuild_firewall >/dev/null 2>&1; : > "$TMP/events"
}
bin_build() { c2_build_of "$TPROXY_BIN"; }
relays_on() { local b="$1" h; shift; for h; do c2_relay_up "$h" && [[ "$(c2_relay_build "$h")" == "$b" ]] || return 1; done; }
recorded_commit() { sed -n 's/^TPROXY_UPSTREAM_COMMIT=//p' "$GLOBAL_ENV"; }
no_relay_start() { ! grep -q '^relay .* started' "$TMP/events"; }
no_backend_action() { ! grep -qE '^systemctl .*twebproxy-mtproxy@' "$TMP/events"; }
protected() { [[ -f "$TMP/firewall.applied" ]] && tr ',' '\n' < "$TMP/firewall.applied" | grep -qx "$1"; }
tmp_leftovers() { find /tmp -maxdepth 1 \( -name 'tproxy-candidate.*' -o -name 'tproxy-old.*' -o -name 'twebproxy-relay-update.*' \) -newer "$TMP/mark" 2>/dev/null | wc -l; }
no_tmp_leftovers() { [[ "$(tmp_leftovers)" == 0 ]]; }
no_bin_debris() { [[ -z "$(find "$(dirname "$TPROXY_BIN")" -maxdepth 1 -name "$(basename "$TPROXY_BIN")?*" ! -name '*.previous')" ]]; }
update() { : > "$TMP/mark"; c2_run update_cmd > "$TMP/out" 2>&1; rc=$?; }
unchanged_after_failed_update() { # $1 = case name
  check "$1_fails" test "$rc" -ne 0
  check "$1_binary_old" test "$(bin_build)" = old
  check "$1_relays_on_old_and_up" relays_on old "$A" "$B"
  check "$1_commit_not_recorded" test "$(recorded_commit)" = "$OLDC"
  check "$1_backends_untouched" no_backend_action
  check "$1_no_temp_or_bin_debris" eval 'no_tmp_leftovers && no_bin_debris'
}

# ---------- 1-3. candidate rejected before anything is replaced ----------
seed; : > "$TMP/fail-go-test"; update; show
unchanged_after_failed_update go_test_failure
check go_test_failure_no_relay_restart no_relay_start
seed; : > "$TMP/fail-go-build"; update
unchanged_after_failed_update go_build_failure
check go_build_failure_no_relay_restart no_relay_start
seed; : > "$TMP/check-fail-candidate-$B"; update; show
unchanged_after_failed_update config_check_failure
check config_check_failure_no_relay_restart no_relay_start
check config_check_failure_names_host grep -q "$B" "$TMP/out"

# ---------- 4. binary write interrupted (ENOSPC-like) ----------
seed; : > "$TMP/fail-bin-write"; update; show
unchanged_after_failed_update bin_write_failure
check bin_write_failure_binary_intact test "$(bin_build)" = old -a -x "$TPROXY_BIN"

# ---------- 5. candidate cannot start on the second relay ----------
seed; : > "$TMP/fail-start-candidate-$B"; update; show
unchanged_after_failed_update restart_failure
check restart_failure_names_relay grep -q "twebproxy@$B.service" "$TMP/out"

# ---------- 6. candidate never becomes ready on the second relay ----------
seed; : > "$TMP/unready-candidate-$B"; update; show
unchanged_after_failed_update readiness_failure
check readiness_failure_names_relay grep -q "$B" "$TMP/out"

# ---------- 7. candidate is ready, then the first relay crashes ----------
seed; : > "$TMP/crash-candidate-$A"; update; show
unchanged_after_failed_update crash_after_ready
check crash_after_ready_names_relay grep -q "$A" "$TMP/out"

# ---------- 8. rollback itself incomplete: reported, never "rolled back" ----------
seed; : > "$TMP/unready-candidate-$B"; : > "$TMP/unready-old-$A"; update; show
check rollback_incomplete_fails test "$rc" -ne 0
check rollback_incomplete_binary_old test "$(bin_build)" = old
check rollback_incomplete_names_unready_relay grep -qE "$A.*(not ready|did not become ready)|(not ready|did not become ready).*$A" "$TMP/out"
check rollback_incomplete_not_claimed_complete not grep -qx '.*The update was rolled back\.' "$TMP/out"

# ---------- 9. relays that need a few seconds to listen (bounded wait) ----------
seed; : > "$TMP/slow-$A"; : > "$TMP/slow-$B"; update; show
check slow_start_succeeds test "$rc" -eq 0
check slow_start_relays_on_candidate relays_on candidate "$A" "$B"
check slow_start_binary_candidate test "$(bin_build)" = candidate

# ---------- 10. success ----------
seed; update; show
check success_rc test "$rc" -eq 0
check success_binary_candidate test "$(bin_build)" = candidate
check success_relays_on_candidate relays_on candidate "$A" "$B"
check success_commit_recorded test "$(recorded_commit)" = "$NEWC"
check success_previous_binary_kept test "$(c2_build_of "$PREV")" = old
check success_backends_untouched no_backend_action
check success_no_temp_or_bin_debris eval 'no_tmp_leftovers && no_bin_debris'
check success_reported grep -q "Relay updated to $NEWC" "$TMP/out"
# 11. no instances: binary replaced, nothing restarted.
seed "$A"; c1_run delete_instance_cmd "$A" >/dev/null 2>&1; : > "$TMP/events"; update
check no_instances_succeeds test "$rc" -eq 0 -a "$(bin_build)" = candidate
check no_instances_no_relay_start no_relay_start

# ---------- 12. interrupted (SIGTERM) while verifying the second relay ----------
seed; : > "$TMP/mark"
C2_AT_PROBE="int:$B" c2_run update_cmd > "$TMP/out" 2>&1 & p=$!
c1_wait_reached int; kill -TERM "$(cat "$TMP/int.pid")" 2>/dev/null; : > "$TMP/int.go"; wait "$p"; rc=$?; show
unchanged_after_failed_update interrupted

# ---------- 13-14. one relay update / relay restart at a time ----------
seed; C2_AT_PROBE="cu:$A" c2_run update_cmd > "$TMP/out1" 2>&1 & p=$!
c1_wait_reached cu; mark="$(wc -l < "$TMP/events")"
TWEBPROXY_STATE_LOCK_WAIT=1 C2_BUILD=second c2_run update_cmd > "$TMP/out2" 2>&1; rc2=$?
TWEBPROXY_STATE_LOCK_WAIT=1 c2_run restart_cmd "$B" > "$TMP/out3" 2>&1; rc3=$?
during="$(tail -n +"$((mark + 1))" "$TMP/events")"
: > "$TMP/cu.go"; wait "$p"; rc1=$?
check concurrent_update_refused test "$rc2" -ne 0
check concurrent_update_no_second_build_installed not grep -q 'build=second' <<<"$during"
check concurrent_update_reports_busy grep -qiE 'busy|another operation' "$TMP/out2"
check restart_during_update_refused test "$rc3" -ne 0
check restart_during_update_touches_nothing not grep -qE "systemctl .*@$B(--main)?\.service" <<<"$during"
check first_update_completes test "$rc1" -eq 0 -a "$(bin_build)" = candidate
check first_update_relays_on_candidate relays_on candidate "$A" "$B"

# ---------- 15-17. restart: instance lock, systemd and readiness failures ----------
seed; install -d -m 0700 "$BASE_DIR/.locks"
exec {held}>>"$BASE_DIR/.locks/instance-$A.lock"; flock "$held"
TWEBPROXY_STATE_LOCK_WAIT=1 c2_run restart_cmd "$A" > "$TMP/out" 2>&1 {held}>&-; rc=$?
exec {held}>&-
check restart_waits_for_instance_lock test "$rc" -ne 0
check restart_locked_touches_nothing not grep -q '^systemctl ' "$TMP/events"
seed; : > "$TMP/fail-restart-twebproxy@$A.service"; c2_run restart_cmd "$A" > "$TMP/out" 2>&1; rc=$?; show
check restart_systemd_failure_fails test "$rc" -ne 0
check restart_systemd_failure_names_unit grep -q "twebproxy@$A.service" "$TMP/out"
check restart_systemd_failure_no_success not grep -q 'was restarted and is ready' "$TMP/out"
seed; : > "$TMP/unready-old-$A"; c2_run restart_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check restart_unready_fails test "$rc" -ne 0 -a "$(grep -c 'did not become ready' "$TMP/out")" -ge 1
seed; c2_run restart_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check restart_success test "$rc" -eq 0 -a "$(grep -c 'was restarted and is ready' "$TMP/out")" -eq 1

# ---------- 18-19. delete: the relay must be proven stopped before anything is removed ----------
seed; : > "$TMP/fail-stop-twebproxy@$A.service"; c2_run delete_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?; show
check delete_relay_stop_failure_fails test "$rc" -ne 0
check delete_relay_stop_failure_instance_kept test -f "$INSTANCES_DIR/$A/instance.env" -a -f "$BACKENDS_DIR/$A--main.env"
check delete_relay_stop_failure_backend_running test -e "$TMP/units/twebproxy-mtproxy@$A--main.service"
check delete_relay_stop_failure_ports_protected protected 23980
check delete_relay_stop_failure_names_relay grep -q "twebproxy@$A.service" "$TMP/out"
check delete_relay_stop_failure_no_success not grep -q "$A was deleted" "$TMP/out"
seed; c2_run delete_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check delete_success test "$rc" -eq 0 -a ! -e "$INSTANCES_DIR/$A" -a ! -e "$TMP/units/twebproxy@$A.service"
check delete_success_reported grep -q "$A was deleted" "$TMP/out"
check delete_success_other_relay_untouched relays_on old "$B"

# ---------- 20. profile add: a relay restart failure is reported ----------
seed; : > "$TMP/fail-restart-twebproxy@$A.service"
C1_NAME=extra c2_run profile_add_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check profile_add_relay_failure_fails test "$rc" -ne 0
check profile_add_relay_failure_no_success not grep -q 'Profile extra was added' "$TMP/out"
seed; C1_NAME=extra c2_run profile_add_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check profile_add_success_reported test "$rc" -eq 0 -a "$(grep -c 'Profile extra was added' "$TMP/out")" -ge 1
check profile_add_success_relay_ready relays_on old "$A"

printf 'c2-relay-lifecycle: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
