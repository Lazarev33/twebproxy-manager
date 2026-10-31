#!/usr/bin/env bash
# F05 regression: concurrent mutations of the same instance are serialized, the
# state read for a read-modify-write is the state under the lock (no lost
# update), port allocation is serialized from choice to persistence, locks are
# released on failure, and an unrelated instance is not blocked.
#
# Deterministic: each race parks one process at a barrier inside an
# interactive prompt (before any lock is taken), runs the competitor to
# completion, then releases the barrier. No timing assumptions beyond bounded
# waits.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-c1-race.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf -- "$TMP"' EXIT
export ROOT MGR TMP
source "$ROOT/tests/stagec1/state-harness.sh"
c1_harness
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
A=alpha.example; B=bravo.example
pf() { printf '%s/%s/profiles.d/%s.env' "$INSTANCES_DIR" "$1" "$2"; }
lockfile() { printf '%s/.locks/instance-%s.lock' "$BASE_DIR" "$1"; }
all_backend_ports() { cat "$BACKENDS_DIR"/*.env | sed -n 's/^MTPROXY_\(CLIENT\|STATS\)_PORT=//p' | sort; }
reset_state() {
  rm -rf "$INSTANCES_DIR" "$BACKENDS_DIR" "$TMP"/*.reached "$TMP"/*.go "$SITES_DIR"
  install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR"; install -d -m 0755 "$SITES_DIR"
  c1_seed_instance "$A" 18080 18081; c1_seed_instance "$B" 18082 18083
  c1_seed_profile "$A" alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa https 23980 28980
  c1_seed_profile "$B" bravo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb https 23981 28981
  c1_run rebuild_profiles_json "$A" >/dev/null 2>&1; c1_run rebuild_profiles_json "$B" >/dev/null 2>&1
}
# Background operation parked at barrier $1; remaining args are the command.
park() { local b="$1"; shift; c1_run "$@" > "$TMP/$b.out" 2>&1 & echo $! > "$TMP/$b.pid"; c1_wait_reached "$b"; }
release() { : > "$TMP/$1.go"; wait "$(cat "$TMP/$1.pid")"; echo $? > "$TMP/$1.rc"; }
show() { grep -E '\[(x|!)\]' "$1" | tail -n 2 | sed 's/^/  | /'; }

# 1. lost update: carrier change parked at its prompt, secret rotation completes.
reset_state
C1_AT_CARRIER=carrier C1_CARRIER=websocket park carrier profile_carrier_cmd "$A" alpha
check race1_parked test -e "$TMP/carrier.reached"
C1_SECRET=cccccccccccccccccccccccccccccccc c1_run profile_rotate_cmd "$A" alpha > "$TMP/rotate.out" 2>&1; rc=$?
check race1_rotation_completes test "$rc" -eq 0
release carrier
check race1_carrier_completes test "$(cat "$TMP/carrier.rc")" -eq 0
check race1_rotated_secret_survives test "$(c1_field "$(pf "$A" alpha)" SECRET)" = cccccccccccccccccccccccccccccccc
check race1_carrier_applied test "$(c1_field "$(pf "$A" alpha)" CARRIER_MODE)" = websocket
check race1_backend_matches_record test "$(c1_field "$BACKENDS_DIR/$A--alpha.env" MTPROXY_SECRET)" = cccccccccccccccccccccccccccccccc

# 2. port allocation: an add parked after choosing ports, a second add on
#    another instance completes; the parked one must not reuse those ports.
reset_state
C1_AT_MAXCONN=addA C1_NAME=second park addA profile_add_cmd "$A"
C1_NAME=other c1_run profile_add_cmd "$B" > "$TMP/addB.out" 2>&1; rc=$?
check race2_competitor_completes test "$rc" -eq 0
release addA
check race2_parked_completes test "$(cat "$TMP/addA.rc")" -eq 0
check race2_backend_ports_unique test -z "$(all_backend_ports | uniq -d)"
check race2_four_profiles_present test "$(ls "$BACKENDS_DIR"/*.env | wc -l)" = 4

# 3. manual ports chosen before a competitor took them: refused, nothing overwritten.
reset_state
C1_AT_MAXCONN=manual C1_NAME=manual C1_MANUAL_PORTS=1 C1_BACKEND_PORT=24100 C1_STATS_PORT=29100 park manual profile_add_cmd "$A"
C1_NAME=taker C1_MANUAL_PORTS=1 C1_BACKEND_PORT=24100 C1_STATS_PORT=29100 c1_run profile_add_cmd "$B" > "$TMP/taker.out" 2>&1; rc=$?
check race3_competitor_completes test "$rc" -eq 0
release manual
check race3_conflict_refused test "$(cat "$TMP/manual.rc")" -ne 0
show "$TMP/manual.out"
check race3_no_record test ! -e "$(pf "$A" manual)"
check race3_competitor_backend_intact test "$(c1_field "$BACKENDS_DIR/$B--taker.env" MTPROXY_CLIENT_PORT)" = 24100
check race3_ports_unique test -z "$(all_backend_ports | uniq -d)"

# 4. same profile name added concurrently: the late one refuses, no overwrite.
reset_state
C1_AT_MAXCONN=dupA C1_NAME=gamma C1_SECRET=11111111111111111111111111111111 park dupA profile_add_cmd "$A"
C1_NAME=gamma C1_SECRET=22222222222222222222222222222222 c1_run profile_add_cmd "$A" > "$TMP/dupB.out" 2>&1
release dupA
check race4_late_duplicate_refused test "$(cat "$TMP/dupA.rc")" -ne 0
show "$TMP/dupA.out"
check race4_first_secret_kept test "$(c1_field "$(pf "$A" gamma)" SECRET)" = 22222222222222222222222222222222

# 5. same hostname added concurrently: the late one refuses, no overwrite.
reset_state
C1_AT_MAXCONN=instA C1_HOST=delta.example C1_NAME=first C1_SECRET=33333333333333333333333333333333 C1_INSTANCE_STUBS=1 park instA add_instance_cmd
C1_HOST=delta.example C1_NAME=winner C1_SECRET=44444444444444444444444444444444 C1_INSTANCE_STUBS=1 c1_run add_instance_cmd > "$TMP/instB.out" 2>&1; rc=$?
check race5_competitor_completes test "$rc" -eq 0
release instA
check race5_late_instance_refused test "$(cat "$TMP/instA.rc")" -ne 0
show "$TMP/instA.out"
check race5_winner_profile_kept test "$(c1_field "$(pf delta.example winner)" SECRET)" = 44444444444444444444444444444444
check race5_no_late_profile test ! -e "$(pf delta.example first)"
check race5_ports_unique test -z "$(all_backend_ports | uniq -d)"

# 6. contention: a held instance lock makes a mutation wait and then fail closed.
reset_state
install -d -m 0700 "$BASE_DIR/.locks"
before="$(cat "$(pf "$A" alpha)")"
exec {holder}>>"$(lockfile "$A")"; flock "$holder"
start=$SECONDS
TWEBPROXY_STATE_LOCK_WAIT=1 C1_SECRET=55555555555555555555555555555555 c1_run profile_rotate_cmd "$A" alpha > "$TMP/busy.out" 2>&1; rc=$?
check contention_fails_closed test "$rc" -ne 0
check contention_bounded_wait test "$((SECONDS - start))" -le 10
check contention_state_unchanged test "$(cat "$(pf "$A" alpha)")" = "$before"
check contention_reports_busy grep -qiE 'busy|занят|lock' "$TMP/busy.out"
show "$TMP/busy.out"
# 7. an unrelated instance is not blocked by that lock.
TWEBPROXY_STATE_LOCK_WAIT=1 C1_SECRET=66666666666666666666666666666666 c1_run profile_rotate_cmd "$B" bravo > "$TMP/other.out" 2>&1; rc=$?
check independent_instance_not_blocked test "$rc" -eq 0
exec {holder}>&-
TWEBPROXY_STATE_LOCK_WAIT=1 C1_SECRET=77777777777777777777777777777777 c1_run profile_rotate_cmd "$A" alpha >/dev/null 2>&1; check after_release_mutation_succeeds test $? -eq 0

# 8. a failed mutation releases its locks; nothing stays held.
: > "$TMP/fail-validate"
C1_SECRET=88888888888888888888888888888888 c1_run profile_rotate_cmd "$A" alpha > "$TMP/failed.out" 2>&1; rc=$?
rm -f "$TMP/fail-validate"
check failed_mutation_reported test "$rc" -ne 0
show "$TMP/failed.out"
check failed_mutation_released_instance_lock flock -n "$(lockfile "$A")" true
check failed_mutation_released_port_lock bash -c '[[ ! -e "$1" ]] || flock -n "$1" true' _ "$BASE_DIR/.locks/ports.lock"
TWEBPROXY_STATE_LOCK_WAIT=1 C1_SECRET=99999999999999999999999999999999 c1_run profile_rotate_cmd "$A" alpha >/dev/null 2>&1; check repeated_invocation_after_failure test $? -eq 0
check lock_files_private test "$(stat -c '%a:%u' "$BASE_DIR/.locks" "$(lockfile "$A")" | sort -u | paste -sd' ')" = "600:0 700:0"

printf 'c1-concurrency: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
