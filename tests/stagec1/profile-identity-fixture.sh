#!/usr/bin/env bash
# F03 regression: creating, rotating, re-carrying or showing one profile must
# never target another. v0.2.13 rebuild_profiles_json sourced every profile into
# the caller's shell, so profile_add_cmd went on to start, report and show the
# alphabetically last profile instead of the new one.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-c1-identity.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stagec1/state-harness.sh"
c1_harness
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
H=alpha.example
pf() { printf '%s/%s/profiles.d/%s.env' "$INSTANCES_DIR" "$H" "$1"; }
started() { grep -qx "restart twebproxy-mtproxy@$H--$1.service" "$TMP/systemctl.calls"; }

c1_seed_instance "$H" 18080 18081
c1_seed_profile "$H" alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa https 23980 28980
c1_seed_profile "$H" zeta ffffffffffffffffffffffffffffffff websocket 23981 28981
: > "$TMP/systemctl.calls"

# --- add "beta" next to "alpha" and "zeta" (beta is neither first nor last) ---
out="$(C1_NAME=beta C1_SECRET=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb C1_CARRIER=https-lanes c1_run profile_add_cmd "$H" 2>&1)"; rc=$?
check add_succeeds test "$rc" -eq 0
check add_created_beta test -f "$(pf beta)"
check add_beta_record_is_beta test "$(c1_field "$(pf beta)" PROFILE_NAME)" = beta
check add_starts_new_backend started beta
check add_does_not_restart_zeta bash -c '! grep -qx "restart twebproxy-mtproxy@$1--zeta.service" "$2"' _ "$H" "$TMP/systemctl.calls"
check add_does_not_restart_alpha bash -c '! grep -qx "restart twebproxy-mtproxy@$1--alpha.service" "$2"' _ "$H" "$TMP/systemctl.calls"
check add_reports_beta grep -q 'beta' <<<"$(grep -iE 'added|добавлен' <<<"$out")"
check add_shows_beta_secret grep -q 'secret=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' <<<"$out"
check add_does_not_show_zeta bash -c '! grep -q "secret=ffffffff" <<<"$1"' _ "$out"
check zeta_untouched test "$(c1_field "$(pf zeta)" SECRET)" = ffffffffffffffffffffffffffffffff
check alpha_untouched test "$(c1_field "$(pf alpha)" SECRET)" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
check profiles_json_three_distinct test "$(jq -r '.profiles|map(.name)|sort|join(",")' "$INSTANCES_DIR/$H/profiles.json")" = alpha,beta,zeta
check beta_backend_env_matches test "$(c1_field "$BACKENDS_DIR/$H--beta.env" MTPROXY_SECRET)" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# --- rotating alpha must only touch alpha (secret) and restart only alpha ---
: > "$TMP/systemctl.calls"
out="$(C1_SECRET=cccccccccccccccccccccccccccccccc c1_run profile_rotate_cmd "$H" alpha 2>&1)"; rc=$?
check rotate_succeeds test "$rc" -eq 0
check rotate_changed_alpha test "$(c1_field "$(pf alpha)" SECRET)" = cccccccccccccccccccccccccccccccc
check rotate_kept_alpha_name test "$(c1_field "$(pf alpha)" PROFILE_NAME)" = alpha
check rotate_left_zeta test "$(c1_field "$(pf zeta)" SECRET)" = ffffffffffffffffffffffffffffffff
check rotate_left_beta test "$(c1_field "$(pf beta)" SECRET)" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
check rotate_restarts_alpha_only test "$(grep -c '^restart twebproxy-mtproxy@' "$TMP/systemctl.calls")" = 1
check rotate_restarts_alpha started alpha
check rotate_shows_alpha grep -q 'secret=cccccccccccccccccccccccccccccccc' <<<"$out"

# --- carrier of zeta: only zeta changes ---
out="$(C1_CARRIER=websocket-lanes c1_run profile_carrier_cmd "$H" zeta 2>&1)"; rc=$?
check carrier_succeeds test "$rc" -eq 0
check carrier_changed_zeta test "$(c1_field "$(pf zeta)" CARRIER_MODE)" = websocket-lanes
check carrier_left_alpha test "$(c1_field "$(pf alpha)" CARRIER_MODE)" = https
check carrier_left_beta test "$(c1_field "$(pf beta)" CARRIER_MODE)" = https-lanes
check carrier_reports_zeta grep -q 'zeta: websocket-lanes' <<<"$out"

# --- a helper that rebuilds profiles.json never moves the caller's identity ---
# Globals as a caller holds them, then the helper, then compare.
identity_after="$(c1_eval 'PROFILE_NAME=beta SECRET=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb BACKEND_PORT=23982
  rebuild_profiles_json alpha.example >/dev/null 2>&1
  printf "%s %s %s" "$PROFILE_NAME" "$SECRET" "$BACKEND_PORT"')"
check rebuild_keeps_caller_identity test "$identity_after" = "beta bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 23982"

# --- a record whose PROFILE_NAME disagrees with its file is refused, not used ---
sed -i 's/^PROFILE_NAME=.*/PROFILE_NAME=zeta/' "$(pf beta)"
before="$(cat "$(pf beta)")"
out="$(C1_SECRET=dddddddddddddddddddddddddddddddd c1_run profile_rotate_cmd "$H" beta 2>&1)"; rc=$?
check mismatched_identity_refused test "$rc" -ne 0
check mismatched_identity_unchanged test "$(cat "$(pf beta)")" = "$before"
check mismatched_identity_zeta_unchanged test "$(c1_field "$(pf zeta)" SECRET)" = ffffffffffffffffffffffffffffffff

# --- names from the command line are validated before any path is built ---
out="$(C1_SECRET=dddddddddddddddddddddddddddddddd c1_run profile_rotate_cmd "$H" ../../../outside 2>&1)"; rc=$?
check traversal_profile_refused test "$rc" -ne 0
out="$(c1_run profile_carrier_cmd "../$H" alpha 2>&1)"; rc=$?
check traversal_host_refused test "$rc" -ne 0

printf 'c1-profile-identity: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
