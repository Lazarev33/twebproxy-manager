#!/usr/bin/env bash
# C1.1 regression (C1-AUD-01, C1-AUD-02): deleting a profile or an instance, or
# reconciling a backend env without a profile, must never take firewall
# protection away from a backend that is not proven stopped. A failed or
# ambiguous stop fails closed (non-zero, diagnostic, records/env/firewall kept);
# a proven stop is followed by state removal and only then the firewall rebuild.
# The protected port set is computed by the real Stage B backend_fw_collect.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-c11-stop.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
export C1_INSTANCE_STUBS=1   # repair/delete/add: never reach frontend, users or Stage 4 paths
source "$ROOT/tests/stagec1/state-harness.sh"
c1_harness
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
not() { ! "$@"; }
show() { grep -E '\[(x|!)\]' "$TMP/out" | tail -n 3 | sed 's/^/  | /'; }
A=alpha.example; B=bravo.example; AB=alpha.example--b
unit() { printf 'twebproxy-mtproxy@%s.service' "$1"; }
running() { [[ -e "$TMP/units/$(unit "$1")" ]]; }           # model process alive
pf() { printf '%s/%s/profiles.d/%s.env' "$INSTANCES_DIR" "$1" "$2"; }
bf() { printf '%s/%s.env' "$BACKENDS_DIR" "$1"; }
protected() { # $1 port: in the firewall set last applied
  [[ -f "$TMP/firewall.applied" ]] && tr ',' '\n' < "$TMP/firewall.applied" | grep -qx "$1"
}
before() { # $1 event regex happens before $2 event regex
  local a b
  a="$(grep -nE "$1" "$TMP/events" | head -n1 | cut -d: -f1)"
  b="$(grep -nE "$2" "$TMP/events" | head -n1 | cut -d: -f1)"
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]
}
setup() {
  rm -rf "$INSTANCES_DIR" "$BACKENDS_DIR" "$TMP"/units/* "$TMP"/fail-* "$TMP"/state-* "$TMP/firewall.applied"
  install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR"
  c1_seed_instance "$A" 18080 18081
  c1_seed_profile "$A" alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa https 23980 28980
  c1_seed_profile "$A" beta bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb https 23981 28981
  c1_seed_instance "$B" 18082 18083
  c1_seed_profile "$B" gamma cccccccccccccccccccccccccccccccc https 23982 28982
  # A live profile of another instance whose id looks like an alpha.example orphan.
  c1_seed_instance "$AB" 18084 18085
  c1_seed_profile "$AB" x dddddddddddddddddddddddddddddddd https 24000 29000
  for h in "$A" "$B" "$AB"; do c1_run rebuild_profiles_json "$h" >/dev/null 2>&1; done
  for id in "$A--alpha" "$A--beta" "$B--gamma" "$AB--x"; do "$TMP/bin/systemctl" start "$(unit "$id")"; done
  c1_eval rebuild_firewall >/dev/null 2>&1
  : > "$TMP/events"
}
fault_stop() { : > "$TMP/fail-stop-$(unit "$1")"; }

# ---------- C1-AUD-01: profile deletion ----------
# 1. disable --now fails, unit stays active.
setup; fault_stop "$A--beta"; old="$(cat "$(pf "$A" beta)")"
c1_run profile_delete_cmd "$A" beta > "$TMP/out" 2>&1; rc=$?
check del_stopfail_nonzero test "$rc" -ne 0
show
check del_stopfail_diagnostic_names_unit grep -q "$(unit "$A--beta")" "$TMP/out"
check del_stopfail_record_kept test "$(cat "$(pf "$A" beta)")" = "$old"
check del_stopfail_backend_env_kept test -f "$(bf "$A--beta")"
check del_stopfail_unit_still_running running "$A--beta"
check del_stopfail_ports_still_protected protected 23981
check del_stopfail_stats_still_protected protected 28981
check del_stopfail_relay_profiles_kept test "$(jq -r '.profiles|map(.name)|sort|join(",")' "$INSTANCES_DIR/$A/profiles.json")" = alpha,beta

# 2. stop reported, but is-active is ambiguous (deactivating / unknown).
for st in deactivating unknown activating; do
  setup; printf '%s\n' "$st" > "$TMP/state-$(unit "$A--beta")"
  c1_run profile_delete_cmd "$A" beta > "$TMP/out" 2>&1; rc=$?
  check "del_ambiguous_${st}_nonzero" test "$rc" -ne 0
  check "del_ambiguous_${st}_record_kept" test -f "$(pf "$A" beta)"
  check "del_ambiguous_${st}_ports_protected" protected 23981
done
# 2b. systemctl is-active itself fails: state unknown.
setup; : > "$TMP/fail-is-active"
c1_run profile_delete_cmd "$A" beta > "$TMP/out" 2>&1; rc=$?
rm -f "$TMP/fail-is-active"
check del_isactive_error_nonzero test "$rc" -ne 0
check del_isactive_error_record_kept test -f "$(pf "$A" beta)" -a -f "$(bf "$A--beta")"
check del_isactive_error_ports_protected protected 23981

# 3. proven stop: record, env and ports go; order is stop -> firewall rebuild.
setup
c1_run profile_delete_cmd "$A" beta > "$TMP/out" 2>&1; rc=$?
check del_success_zero test "$rc" -eq 0
check del_success_record_removed test ! -e "$(pf "$A" beta)" -a ! -e "$(bf "$A--beta")"
check del_success_unit_stopped not running "$A--beta"
check del_success_ports_released not protected 23981
check del_success_stop_before_rebuild before "systemctl disable --now $(unit "$A--beta")" '^rebuild '
check del_success_alpha_untouched running "$A--alpha"
check del_success_alpha_protected protected 23980

# 4. stop proven, then the state commit fails validation: previous state and
#    the running backend are restored, ports stay protected, non-zero result.
setup; old="$(cat "$(pf "$A" beta)")"; : > "$TMP/fail-validate"
c1_run profile_delete_cmd "$A" beta > "$TMP/out" 2>&1; rc=$?
rm -f "$TMP/fail-validate"
check del_postfail_nonzero test "$rc" -ne 0
show
check del_postfail_record_restored test "$(cat "$(pf "$A" beta)")" = "$old"
check del_postfail_env_restored test "$(c1_field "$(bf "$A--beta")" MTPROXY_SECRET)" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
check del_postfail_backend_running_again running "$A--beta"
check del_postfail_ports_protected protected 23981
check del_postfail_no_temp_files test -z "$(find "$INSTANCES_DIR" "$BACKENDS_DIR" -name '.*' -type f)"

# ---------- instance deletion (same stop helper) ----------
setup; fault_stop "$A--beta"
c1_run delete_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check delinst_stopfail_nonzero test "$rc" -ne 0
show
check delinst_stopfail_instance_kept test -f "$INSTANCES_DIR/$A/instance.env" -a -f "$(pf "$A" beta)"
check delinst_stopfail_envs_kept test -f "$(bf "$A--beta")" -a -f "$(bf "$A--alpha")"
check delinst_stopfail_ports_protected protected 23981
setup
c1_run delete_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check delinst_success_zero test "$rc" -eq 0
check delinst_success_removed test ! -e "$INSTANCES_DIR/$A" -a ! -e "$(bf "$A--beta")" -a ! -e "$(bf "$A--alpha")"
check delinst_success_ports_released not protected 23981
check delinst_success_unrelated_kept test -f "$(bf "$B--gamma")" -a -f "$(bf "$AB--x")"
check delinst_success_unrelated_running running "$AB--x"

# ---------- C1-AUD-02: backend env without a profile (interrupted removal) ----------
orphan() { setup; rm -f "$(pf "$A" beta)"; c1_run rebuild_profiles_json "$A" >/dev/null 2>&1; }
# Unrelated objects next to the orphan. They stay valid backend state for the
# Stage B firewall, which (by design) refuses symlinked or malformed *.env.
foreign_files() {
  printf 'MTPROXY_CLIENT_PORT=24900\nMTPROXY_STATS_PORT=29900\n' > "$BACKENDS_DIR/alpha.example--Bad.Name.env"  # not a profile name
  : > "$BACKENDS_DIR/alpha.example--notes.txt"
}
foreign_snapshot() { (cd "$BACKENDS_DIR" && sha256sum alpha.example--Bad.Name.env alpha.example--notes.txt "$B--gamma.env" "$AB--x.env" && stat -c '%n %a %Y' alpha.example--Bad.Name.env alpha.example--notes.txt "$B--gamma.env" "$AB--x.env"); }
# 5. orphan whose unit cannot be proven stopped: repair fails closed.
orphan; fault_stop "$A--beta"
c1_run repair_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check orphan_active_repair_nonzero test "$rc" -ne 0
show
check orphan_active_diagnostic_names_unit grep -q "$(unit "$A--beta")" "$TMP/out"
check orphan_active_env_kept test -f "$(bf "$A--beta")"
check orphan_active_unit_running running "$A--beta"
check orphan_active_ports_protected protected 23981
# 6. orphan whose unit stops: reconciled in order stop -> env removal -> rebuild.
orphan; foreign_files; fsnap="$(foreign_snapshot)"
c1_run repair_instance_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check orphan_stopped_repair_zero test "$rc" -eq 0
check orphan_stopped_unit_stopped not running "$A--beta"
check orphan_stopped_env_removed test ! -e "$(bf "$A--beta")"
check orphan_stopped_ports_released not protected 23981
check orphan_stopped_stop_before_rebuild before "systemctl disable --now $(unit "$A--beta")" '^rebuild '
# 7. unrelated objects survive reconciliation untouched.
check orphan_unrelated_files_unchanged test "$(foreign_snapshot)" = "$fsnap"
check orphan_unrelated_foreign_ports_protected protected 24900
check orphan_unrelated_live_lookalike_running running "$AB--x"
check orphan_unrelated_live_lookalike_not_stopped not grep -q "disable --now $(unit "$AB--x")" "$TMP/events"
check orphan_unrelated_other_instance_running running "$B--gamma"
check orphan_live_profiles_restarted running "$A--alpha"
# 8. a new profile never overwrites an orphan env of the same id.
orphan; fault_stop "$A--beta"; oldenv="$(cat "$(bf "$A--beta")")"
C1_NAME=beta c1_run profile_add_cmd "$A" > "$TMP/out" 2>&1; rc=$?
check add_over_orphan_refused test "$rc" -ne 0
show
check add_over_orphan_env_unchanged test "$(cat "$(bf "$A--beta")")" = "$oldenv"
check add_over_orphan_no_record test ! -e "$(pf "$A" beta)"
# 9. a new instance over orphan envs of its hostname: reconciled first, or refused.
setup; rm -rf "$INSTANCES_DIR/$B"; fault_stop "$B--gamma"; oldenv="$(cat "$(bf "$B--gamma")")"
C1_HOST="$B" C1_NAME=gamma c1_run add_instance_cmd > "$TMP/out" 2>&1; rc=$?
check addinst_over_active_orphan_refused test "$rc" -ne 0
check addinst_over_active_orphan_env_unchanged test "$(cat "$(bf "$B--gamma")")" = "$oldenv"
check addinst_over_active_orphan_running running "$B--gamma"
rm -f "$TMP/fail-stop-$(unit "$B--gamma")"; rm -rf "$INSTANCES_DIR/$B" "$SITES_DIR/$B"
C1_HOST="$B" C1_NAME=gamma C1_SECRET=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee c1_run add_instance_cmd > "$TMP/out" 2>&1; rc=$?
check addinst_over_stoppable_orphan_succeeds test "$rc" -eq 0
check addinst_over_stoppable_orphan_new_secret test "$(c1_field "$(bf "$B--gamma")" MTPROXY_SECRET)" = eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
check addinst_stop_before_new_env before "systemctl disable --now $(unit "$B--gamma")" "systemctl enable --now $(unit "$B--gamma")"

printf 'c11-backend-stop: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
