#!/usr/bin/env bash
# C1.2 regression (C11-AUD-03, C11-AUD-04): a backend id is <host>--<profile>
# and both parts may contain "--", so one id can name two (hostname, profile)
# pairs. No operation on instance A may stop, rewrite or remove a backend that
# could belong to another instance B; a collision is refused before any file,
# unit or firewall change; an id whose owner cannot be proven is kept (with its
# firewall protection) and the operation fails closed.
# Overlapping/colliding states are seeded directly: they model data written by
# earlier versions, which the current create paths no longer allow.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-c12-identity.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf -- "$TMP"' EXIT
export C1_INSTANCE_STUBS=1   # repair/delete/add never reach frontend, users or Stage 4 paths
source "$ROOT/tests/stagec1/state-harness.sh"
c1_harness
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
not() { ! "$@"; }
show() { grep -E '\[(x|!)\]' "$TMP/out" | tail -n 3 | sed 's/\x1b\[[0-9;]*m//g; s/^/  | /'; }
A=alpha.example; B=alpha.example--b
unit() { printf 'twebproxy-mtproxy@%s.service' "$1"; }
running() { [[ -e "$TMP/units/$(unit "$1")" ]]; }
pf() { printf '%s/%s/profiles.d/%s.env' "$INSTANCES_DIR" "$1" "$2"; }
bf() { printf '%s/%s.env' "$BACKENDS_DIR" "$1"; }
protected() { [[ -f "$TMP/firewall.applied" ]] && tr ',' '\n' < "$TMP/firewall.applied" | grep -qx "$1"; }
touched() { grep -qE "systemctl (disable|restart|enable|stop|start)( --now)? $(unit "$1")\$" "$TMP/events"; }
reset() {
  rm -rf "$INSTANCES_DIR" "$BACKENDS_DIR" "$SITES_DIR" "$TMP"/units/* "$TMP"/fail-* "$TMP"/state-* \
    "$TMP/firewall.applied" "$TMP"/*.reached "$TMP"/*.go
  install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR"; install -d -m 0755 "$SITES_DIR"
}
start() { for id; do "$TMP/bin/systemctl" start "$(unit "$id")"; done; }
finish_setup() { # rebuild profiles.json of the given hosts, apply firewall, clear event log
  local h; for h; do c1_run rebuild_profiles_json "$h" >/dev/null 2>&1; done
  c1_eval rebuild_firewall >/dev/null 2>&1; : > "$TMP/events"
}
# Duplicate concurrent creation: the test holds the shared port lock, starts two
# creates of one backend id (without the held fd, which would keep the lock),
# waits until both block in flock, then releases.
in_flock() { local c; for c in $(pgrep -P "$1"); do [[ "$(cat "/proc/$c/comm" 2>/dev/null)" == flock ]] && return 0; in_flock "$c" && return 0; done; return 1; }
wait_in_flock() { local i; for ((i = 0; i < 200; i++)); do in_flock "$1" && return 0; sleep 0.05; done; return 1; }
hold_ports() { install -d -m 0700 "$BASE_DIR/.locks"; exec {held}>>"$BASE_DIR/.locks/ports.lock"; flock "$held"; }
field() { sed -n "s/^$1=//p" "$2" 2>/dev/null; }   # $1=key $2=file
won() { [[ -f "$(pf "$1" "$2")" ]]; }
snap_b() { cat "$(bf "$B--x")" 2>/dev/null; cat "$TMP/units/$(unit "$B--x")" 2>/dev/null; }

# ---------- C11-AUD-04: colliding ids on create paths ----------
# 1. B/x live; creating A with first profile b--x would alias B/x.
reset; c1_seed_instance "$B" 18082 18083
c1_seed_profile "$B" x bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb https 23981 28981
start "$B--x"; finish_setup "$B"; before="$(snap_b)"
C1_HOST="$A" C1_NAME='b--x' C1_SECRET=dddddddddddddddddddddddddddddddd c1_run add_instance_cmd > "$TMP/out" 2>&1; rc=$?
check create_collision_refused test "$rc" -ne 0
show
check create_collision_b_env_and_unit_unchanged test "$(snap_b)" = "$before"
check create_collision_b_unit_not_touched not touched "$B--x"
check create_collision_no_instance_a test ! -e "$INSTANCES_DIR/$A"
check create_collision_no_firewall_rebuild not grep -q '^rebuild' "$TMP/events"
check create_collision_b_ports_protected protected 23981
# 2. Any hostname that is a "--" extension of an existing one (either way) is refused.
C1_HOST="$A" C1_NAME=main c1_run add_instance_cmd > "$TMP/out" 2>&1; rc=$?
check create_prefix_of_existing_refused test "$rc" -ne 0 -a ! -e "$INSTANCES_DIR/$A"
check create_prefix_reports_overlap grep -q "overlaps with $B in backend names" "$TMP/out"
reset; c1_seed_instance "$A" 18080 18081
c1_seed_profile "$A" alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa https 23980 28980
start "$A--alpha"; finish_setup "$A"
C1_HOST="$B" C1_NAME=x c1_run add_instance_cmd > "$TMP/out" 2>&1; rc=$?
check create_extension_of_existing_refused test "$rc" -ne 0 -a ! -e "$INSTANCES_DIR/$B"
check create_extension_a_untouched not touched "$A--alpha"
# 3. Controls: unrelated, single-dash and dotted "--" extensions (b.com--<profile>
#    is no profile name, so ids cannot coincide) are still created normally.
C1_HOST=beta.example C1_NAME=default c1_run add_instance_cmd > "$TMP/out" 2>&1; rc=$?
check create_unrelated_host_allowed test "$rc" -eq 0 -a -f "$(pf beta.example default)"
C1_HOST=alpha.example-b C1_NAME=default c1_run add_instance_cmd > "$TMP/out" 2>&1; rc=$?
check create_single_dash_host_allowed test "$rc" -eq 0 -a -f "$(pf alpha.example-b default)"
C1_HOST="$A--b.com" C1_NAME=default c1_run add_instance_cmd > "$TMP/out" 2>&1; rc=$?
check create_dotted_extension_allowed test "$rc" -eq 0 -a -f "$(pf "$A--b.com" default)"
check create_dotted_extension_a_untouched not touched "$A--alpha"
# 4. Concurrent creation of A and B: the parked one must see the other under the shared lock.
reset; C1_AT_MAXCONN=pa C1_HOST="$A" C1_NAME=main c1_run add_instance_cmd > "$TMP/pa.out" 2>&1 & pa=$!
c1_wait_reached pa
C1_HOST="$B" C1_NAME=x c1_run add_instance_cmd > "$TMP/out" 2>&1; rc_b=$?
: > "$TMP/pa.go"; wait "$pa"; rc_a=$?
check concurrent_create_first_succeeds test "$rc_b" -eq 0
check concurrent_create_overlap_refused test "$rc_a" -ne 0 -a ! -e "$INSTANCES_DIR/$A"
# 4b. Both first profiles give alpha.example--b--x; both creates wait on the held lock.
reset; hold_ports
C1_HOST="$A" C1_NAME='b--x' C1_SECRET=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 c1_run add_instance_cmd > "$TMP/ra.out" 2>&1 {held}>&- & ra=$!
C1_HOST="$B" C1_NAME=x C1_SECRET=b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2 c1_run add_instance_cmd > "$TMP/rb.out" 2>&1 {held}>&- & rb=$!
wait_in_flock "$ra"; wait_in_flock "$rb"
check dup_create_both_waited_on_port_lock eval 'in_flock "$ra" && in_flock "$rb"'
exec {held}>&-; wait "$ra"; rc_a=$?; wait "$rb"; rc_b=$?
check dup_create_exactly_one_wins test "$(( (rc_a == 0) + (rc_b == 0) ))" -eq 1
check dup_create_exactly_one_instance test "$(find "$INSTANCES_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1
if won "$A" 'b--x'; then wh="$A"; wp='b--x'; else wh="$B"; wp=x; fi
check dup_create_env_is_winners test -f "$(bf "$A--b--x")" -a "$(field MTPROXY_SECRET "$(bf "$A--b--x")")" = "$(field SECRET "$(pf "$wh" "$wp")")" \
  -a "$(field MTPROXY_CLIENT_PORT "$(bf "$A--b--x")")" = "$(field BACKEND_PORT "$(pf "$wh" "$wp")")"
check dup_create_winner_port_protected protected "$(field BACKEND_PORT "$(pf "$wh" "$wp")")"

# ---------- profile ids in a state with overlapping hostnames (earlier versions) ----------
legacy() {
  reset; c1_seed_instance "$A" 18080 18081; c1_seed_instance "$B" 18082 18083
  c1_seed_profile "$A" alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa https 23980 28980
  c1_seed_profile "$B" x bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb https 23981 28981
  c1_seed_profile "$B" y cccccccccccccccccccccccccccccccc https 23982 28982
  start "$A--alpha" "$B--x" "$B--y"; finish_setup "$A" "$B"
}
# 5. A cannot add b--x while B/x is live.
legacy; before="$(snap_b)"
C1_NAME='b--x' c1_run profile_add_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check profile_collision_refused test "$rc" -ne 0
check profile_collision_b_unchanged test "$(snap_b)" = "$before"
check profile_collision_no_a_record test ! -e "$(pf "$A" 'b--x')"
check profile_collision_no_firewall_rebuild not grep -q '^rebuild' "$TMP/events"
# 6. Control: B can add z (no live pair shares that id); A then cannot add b--z.
C1_NAME=z c1_run profile_add_cmd "$B" > "$TMP/out" 2>&1; rc=$?
check profile_noncolliding_allowed test "$rc" -eq 0 -a -f "$(pf "$B" z)"
C1_NAME='b--z' c1_run profile_add_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check profile_collision_after_add_refused test "$rc" -ne 0 -a ! -e "$(pf "$A" 'b--z')"
# 6b. Concurrent A/b--w and B/w (same new id) on existing hosts, both waiting on the held lock.
legacy; hold_ports
C1_NAME='b--w' C1_SECRET=c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3 c1_run profile_add_cmd "$A" > "$TMP/ra.out" 2>&1 {held}>&- & ra=$!
C1_NAME=w C1_SECRET=d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4 c1_run profile_add_cmd "$B" > "$TMP/rb.out" 2>&1 {held}>&- & rb=$!
wait_in_flock "$ra"; wait_in_flock "$rb"
check dup_profile_both_waited_on_port_lock eval 'in_flock "$ra" && in_flock "$rb"'
exec {held}>&-; wait "$ra"; rc_a=$?; wait "$rb"; rc_b=$?
check dup_profile_exactly_one_wins test "$(( (rc_a == 0) + (rc_b == 0) ))" -eq 1
check dup_profile_exactly_one_record test "$(( $(won "$A" 'b--w' && echo 1 || echo 0) + $(won "$B" w && echo 1 || echo 0) ))" -eq 1
if won "$A" 'b--w'; then wh="$A"; wp='b--w'; else wh="$B"; wp=w; fi
check dup_profile_env_is_winners test -f "$(bf "$A--b--w")" -a "$(field MTPROXY_SECRET "$(bf "$A--b--w")")" = "$(field SECRET "$(pf "$wh" "$wp")")" \
  -a "$(field MTPROXY_CLIENT_PORT "$(bf "$A--b--w")")" = "$(field BACKEND_PORT "$(pf "$wh" "$wp")")"
check dup_profile_loser_reports_collision grep -q 'already used by a profile of another instance' "$TMP/ra.out" "$TMP/rb.out"
check dup_profile_others_untouched eval 'running "$A--alpha" && running "$B--x" && running "$B--y"'

# ---------- C11-AUD-04: an id already shared by two live pairs (written by an earlier version) ----------
shared() {
  legacy; c1_seed_profile "$A" 'b--x' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb https 23981 28981
  finish_setup "$A" "$B"; before="$(snap_b)"
}
for op in "profile_rotate_cmd $A b--x" "profile_carrier_cmd $B x" "profile_delete_cmd $A b--x" \
          "profile_delete_cmd $B x" "repair_instance_cmd $A" "repair_instance_cmd $B" "delete_instance_cmd $A"; do
  shared; name="shared_${op// /_}"; name="${name//./_}"
  C1_SECRET=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee C1_CARRIER=websocket c1_run $op > "$TMP/out" 2>&1; rc=$?
  check "${name}_refused" test "$rc" -ne 0
  check "${name}_backend_unchanged" test "$(snap_b)" = "$before"
  check "${name}_unit_not_touched" not touched "$B--x"
  check "${name}_records_kept" test -f "$(pf "$A" 'b--x')" -a -f "$(pf "$B" x)" -a -f "$INSTANCES_DIR/$A/instance.env"
  check "${name}_ports_protected" protected 23981
done
show

# ---------- C11-AUD-03: orphan whose name another instance could own ----------
orphan_b() { legacy; rm -f "$(pf "$B" x)"; finish_setup "$B"; before="$(snap_b)"; }
# 7. repair(A) must not touch B's orphan (audit scenario) ...
orphan_b; c1_run repair_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check orphan_cross_repair_a_fails_closed test "$rc" -ne 0
show
check orphan_cross_repair_a_b_untouched test "$(snap_b)" = "$before"
check orphan_cross_repair_a_unit_not_touched not touched "$B--x"
check orphan_cross_repair_a_ports_protected protected 23981
# ... nor repair(B): the name also splits into (alpha.example, b--x); owner unproven.
orphan_b; c1_run repair_instance_cmd "$B" > "$TMP/out" 2>&1; rc=$?
check orphan_cross_repair_b_fails_closed test "$rc" -ne 0 -a "$(snap_b)" = "$before"
# 8. delete_instance(A) refuses and deletes nothing while such a leftover exists.
orphan_b; c1_run delete_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check orphan_cross_delete_a_refused test "$rc" -ne 0 -a -f "$INSTANCES_DIR/$A/instance.env"
check orphan_cross_delete_a_b_untouched test "$(snap_b)" = "$before"
check orphan_cross_delete_a_own_backend_running running "$A--alpha"
# 9. Leftover of a fully deleted B: still not attributable to A.
orphan_b; rm -rf "$INSTANCES_DIR/$B"; finish_setup "$A"; before="$(snap_b)"
c1_run repair_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check orphan_deleted_owner_repair_fails_closed test "$rc" -ne 0 -a "$(snap_b)" = "$before"
check orphan_deleted_owner_ports_protected protected 23981
# 10. ... and creating A over such a leftover is refused without touching it.
rm -rf "$INSTANCES_DIR/$A" "$SITES_DIR/$A"; rm -f "$(bf "$A--alpha")"; finish_setup; before="$(snap_b)"
C1_HOST="$A" C1_NAME=main c1_run add_instance_cmd > "$TMP/out" 2>&1; rc=$?
check create_over_unattributable_leftover_refused test "$rc" -ne 0 -a "$(snap_b)" = "$before"
check create_over_unattributable_leftover_no_instance test ! -e "$INSTANCES_DIR/$A"
# 11. Control: an orphan whose name splits only one way is still reconciled.
legacy; c1_seed_profile "$A" beta 99999999999999999999999999999999 https 23985 28985
start "$A--beta"; rm -f "$(pf "$A" beta)"; finish_setup "$A" "$B"
c1_run repair_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check orphan_unique_reconciled test "$rc" -eq 0 -a ! -e "$(bf "$A--beta")"
check orphan_unique_unit_stopped not running "$A--beta"
check orphan_unique_b_untouched running "$B--x"
check orphan_unique_ports_released not protected 23985
# 12. Known limitation, fail closed: "--" in the last label (IDN zone) makes every
#     orphan name split two ways (xn--e1afmkfd.xn + p1ai--beta); a "--" in an
#     earlier label (IDN second level) does not.
for h in xn--e1afmkfd.xn--p1ai xn--e1afmkfd.example; do
  reset; c1_seed_instance "$h" 18080 18081
  c1_seed_profile "$h" alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa https 23980 28980
  c1_seed_profile "$h" beta 99999999999999999999999999999999 https 23985 28985
  start "$h--alpha" "$h--beta"; rm -f "$(pf "$h" beta)"; finish_setup "$h"
  c1_run repair_instance_cmd "$h" > "$TMP/out" 2>&1; rc=$?
  if [[ "$h" == *.xn--* ]]; then
    check orphan_idn_zone_fails_closed test "$rc" -ne 0 -a -e "$(bf "$h--beta")"
    check orphan_idn_zone_unit_not_touched not touched "$h--beta"
    check orphan_idn_zone_ports_protected protected 23985
  else
    check orphan_idn_label_reconciled test "$rc" -eq 0 -a ! -e "$(bf "$h--beta")"
  fi
done

printf 'c12-backend-identity: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
