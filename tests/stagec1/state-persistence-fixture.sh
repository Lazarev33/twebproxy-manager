#!/usr/bin/env bash
# F04 regression: profile/instance state writes. A failed write must not be
# reported as success and must not destroy the previous valid record; related
# profile/backend/profiles.json state ends in a defined consistent state; stale
# or foreign shell variables never leak into a saved record; the on-disk format
# stays what v0.2.13 wrote. Write failures are injected command failures, not a
# real ENOSPC (that needs a disposable lab mount).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-c1-state.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stagec1/state-harness.sh"
c1_harness
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
H=alpha.example
pf() { printf '%s/%s/profiles.d/%s.env' "$INSTANCES_DIR" "$H" "$1"; }
bf() { printf '%s/%s--%s.env' "$BACKENDS_DIR" "$H" "$1"; }
pj() { printf '%s/%s/profiles.json' "$INSTANCES_DIR" "$H"; }
json_secret() { jq -r --arg n "$1" '.profiles[]|select(.name==$n)|.secret' "$(pj)"; }
snap() { cat "$(pf alpha)" "$(bf alpha)" "$(pj)" 2>/dev/null | sha256sum; }
show() { grep -E '\[(x|!)\]' "$TMP/out" | tail -n 2 | sed 's/^/  | /'; }
no_temp_files() { test -z "$(find "$INSTANCES_DIR" "$BACKENDS_DIR" -name '.*' -type f ! -name '*.lock' 2>/dev/null)"; }

# Write faults: C1_FAULT + $TMP/fault and $TMP/fault-jq (see state-harness.sh).
reset_state() {
  rm -rf "$INSTANCES_DIR" "$BACKENDS_DIR"; install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR"
  c1_seed_instance "$H" 18080 18081
  c1_seed_profile "$H" alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa https 23980 28980 4
  c1_seed_profile "$H" zeta ffffffffffffffffffffffffffffffff websocket 23981 28981
  c1_run rebuild_profiles_json "$H" >/dev/null 2>&1
  rm -f "$TMP"/fault* "$TMP/fail-validate"; unset C1_FAULT
}
rotate() { C1_SECRET=cccccccccccccccccccccccccccccccc c1_run profile_rotate_cmd "$H" alpha > "$TMP/out" 2>&1; }

# 1. profile record write fails mid-file: no success, previous record intact.
reset_state; before="$(snap)"; old_pf="$(cat "$(pf alpha)")"
export C1_FAULT='CARRIER_MODE='; : > "$TMP/fault"
if rotate; then bad profile_write_failure_reported; else ok profile_write_failure_reported; fi
show
check profile_write_previous_record_intact test "$(cat "$(pf alpha)")" = "$old_pf"
check profile_write_related_state_intact test "$(snap)" = "$before"
check profile_write_no_temp_files no_temp_files

# 2. backend env write fails after the profile record: defined consistent state.
reset_state; before="$(snap)"
export C1_FAULT='MTPROXY_CLIENT_PORT='; : > "$TMP/fault"
if rotate; then bad backend_write_failure_reported; else ok backend_write_failure_reported; fi
show
check backend_write_profile_secret_consistent test "$(c1_field "$(pf alpha)" SECRET)" = "$(c1_field "$(bf alpha)" MTPROXY_SECRET)"
check backend_write_json_consistent test "$(json_secret alpha)" = "$(c1_field "$(pf alpha)" SECRET)"
check backend_write_previous_state_kept test "$(snap)" = "$before"
check backend_write_backend_env_complete test "$(grep -c '^MTPROXY_' "$(bf alpha)")" = 5
check backend_write_no_temp_files no_temp_files

# 3. profiles.json generation fails: previous profiles.json kept, no success.
reset_state; before="$(snap)"; : > "$TMP/fault-jq"
if rotate; then bad json_failure_reported; else ok json_failure_reported; fi
show
check json_failure_profiles_json_valid jq -e '.profiles|length==2' "$(pj)"
check json_failure_consistent test "$(json_secret alpha)" = "$(c1_field "$(pf alpha)" SECRET)"
check json_failure_previous_state_kept test "$(snap)" = "$before"

# 4. validation rejects the new state: previous record restored.
reset_state; before="$(snap)"; : > "$TMP/systemctl.calls"; : > "$TMP/fail-validate"
if rotate; then bad validation_failure_reported; else ok validation_failure_reported; fi
show
check validation_failure_state_restored test "$(snap)" = "$before"
check validation_failure_no_restart bash -c '! grep -q "^restart twebproxy-mtproxy@" "$1" 2>/dev/null' _ "$TMP/systemctl.calls"
rm -f "$TMP/fail-validate"

# 5. a new profile that fails validation leaves nothing behind.
reset_state; : > "$TMP/systemctl.calls"; : > "$TMP/fail-validate"
if C1_NAME=gamma C1_SECRET=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee c1_run profile_add_cmd "$H" > "$TMP/out" 2>&1; then bad add_validation_failure_reported; else ok add_validation_failure_reported; fi
show
check add_validation_no_profile_record test ! -e "$(pf gamma)"
check add_validation_no_backend_env test ! -e "$(bf gamma)"
check add_validation_json_unchanged test "$(jq -r '.profiles|map(.name)|sort|join(",")' "$(pj)")" = alpha,zeta
check add_validation_no_backend_started bash -c '! grep -q "gamma" "$1"' _ "$TMP/systemctl.calls"
rm -f "$TMP/fail-validate"

# 6. success keeps the v0.2.13 record format, ownership/mode and CREATED_AT.
reset_state
check rotate_succeeds rotate
check format_profile_keys_in_order test "$(cut -d= -f1 "$(pf alpha)" | paste -sd, -)" = PROFILE_NAME,SECRET,CARRIER_MODE,BACKEND_PORT,STATS_PORT,WORKERS,MAX_CONNECTIONS,CREATED_AT
check format_backend_keys_in_order test "$(cut -d= -f1 "$(bf alpha)" | paste -sd, -)" = MTPROXY_SECRET,MTPROXY_CLIENT_PORT,MTPROXY_STATS_PORT,MTPROXY_WORKERS,MTPROXY_MAX_CONNECTIONS
check format_profile_sourcable bash -c 'source "$1" && [[ $SECRET == cccccccccccccccccccccccccccccccc && $WORKERS == 4 ]]' _ "$(pf alpha)"
check format_profile_mode test "$(stat -c '%a:%u:%g' "$(pf alpha)")" = 600:0:0
check format_backend_mode test "$(stat -c '%a:%u:%g' "$(bf alpha)")" = 600:0:0
check format_json_mode test "$(stat -c '%a:%u:%g' "$(pj)")" = 400:0:0
check format_json_shape jq -e '.profiles|all(keys==["backend","carrier_mode","name","secret"])' "$(pj)"
check rotate_preserves_created_at test "$(c1_field "$(pf alpha)" CREATED_AT)" = 2026-01-02T00:00:00+00:00
C1_CARRIER=websocket c1_run profile_carrier_cmd "$H" zeta >/dev/null 2>&1
check carrier_preserves_created_at test "$(c1_field "$(pf zeta)" CREATED_AT)" = 2026-01-02T00:00:00+00:00
C1_SECRET=dd0123456789abcdef0123456789abcdef c1_run profile_rotate_cmd "$H" alpha >/dev/null 2>&1
check dd_secret_profile_kept test "$(c1_field "$(pf alpha)" SECRET)" = dd0123456789abcdef0123456789abcdef
check dd_secret_backend_stripped test "$(c1_field "$(bf alpha)" MTPROXY_SECRET)" = 0123456789abcdef0123456789abcdef

# 7. stale globals from an earlier operation in the same shell never leak.
reset_state
sed -i '/^WORKERS=/d' "$(pf zeta)"   # damaged record: key missing
old_zeta="$(cat "$(pf zeta)")"
if C1_SECRET=dddddddddddddddddddddddddddddddd c1_eval 'load_profile alpha.example alpha; profile_rotate_cmd alpha.example zeta' > "$TMP/out" 2>&1; then bad damaged_record_refused; else ok damaged_record_refused; fi
show
check damaged_record_unchanged test "$(cat "$(pf zeta)")" = "$old_zeta"
check no_inherited_workers bash -c '! grep -qx "WORKERS=4" "$1"' _ "$(pf zeta)"

# 7b. the damaged record can still be deleted, which heals the instance.
c1_run profile_delete_cmd "$H" zeta > "$TMP/out" 2>&1; rc=$?
check damaged_record_deletable test "$rc" -eq 0
check damaged_record_removed test ! -e "$(pf zeta)" -a ! -e "$(bf zeta)"
check damaged_delete_keeps_alpha test "$(json_secret alpha)" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
check healed_instance_mutable rotate

# 8. a record cannot redefine the manager's variables.
reset_state
printf 'BACKENDS_DIR=%q\n' "$TMP/foreign" >> "$(pf zeta)"
foreign_after="$(c1_eval 'rebuild_profiles_json alpha.example >/dev/null 2>&1; load_profile alpha.example zeta; printf "%s" "$BACKENDS_DIR"')"
check foreign_variable_not_imported test "$foreign_after" = "$BACKENDS_DIR"

# 9. symlinked records are refused and their targets left alone.
reset_state
mv "$(pf alpha)" "$TMP/real-alpha.env"; ln -s "$TMP/real-alpha.env" "$(pf alpha)"
target_before="$(cat "$TMP/real-alpha.env")"
if rotate; then bad symlink_record_refused; else ok symlink_record_refused; fi
show
check symlink_target_untouched test "$(cat "$TMP/real-alpha.env")" = "$target_before"

# 10. an interrupted earlier commit (record new, backend env old) is healed by
#     the next mutation of the same instance.
reset_state
sed -i 's/^SECRET=.*/SECRET=99999999999999999999999999999999/' "$(pf zeta)"
check heal_precondition_inconsistent test "$(c1_field "$(bf zeta)" MTPROXY_SECRET)" = ffffffffffffffffffffffffffffffff
check heal_other_mutation_succeeds rotate
check heal_backend_env_rederived test "$(c1_field "$(bf zeta)" MTPROXY_SECRET)" = 99999999999999999999999999999999
check heal_json_rederived test "$(json_secret zeta)" = 99999999999999999999999999999999

# 11. instance.env is replaced atomically too.
reset_state
old_inst="$(cat "$INSTANCES_DIR/$H/instance.env")"
save_inst='load_instance alpha.example; TLS_MODE=caddy; save_instance alpha.example'
export C1_FAULT='TLS_MODE='; : > "$TMP/fault"
if c1_eval "$save_inst" > "$TMP/out" 2>&1; then bad instance_write_failure_reported; else ok instance_write_failure_reported; fi
show
check instance_write_previous_intact test "$(cat "$INSTANCES_DIR/$H/instance.env")" = "$old_inst"
unset C1_FAULT
check instance_write_succeeds c1_eval "$save_inst"
check instance_write_applied test "$(c1_field "$INSTANCES_DIR/$H/instance.env" TLS_MODE)" = caddy
check instance_write_keeps_created_at test "$(c1_field "$INSTANCES_DIR/$H/instance.env" CREATED_AT)" = 2026-01-01T00:00:00+00:00
check instance_write_mode test "$(stat -c '%a:%u:%g' "$INSTANCES_DIR/$H/instance.env")" = 600:0:0

printf 'c1-state-persistence: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
