#!/usr/bin/env bash
# TG-7 (backend portion) / TWP-005 regression.
#
# rebuild_firewall() sourced every backends/*.env into one shell with no unset
# and no defaults, so a truncated file inherited the previous backend's ports.
# The generated isolation ruleset then omitted a real backend port, leaving it
# reachable from the internet with no error reported.
#
# Usage: tg7-backend-state-isolation.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }

TMP="$(mktemp -d /tmp/tg7-backend.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT

# shellcheck source=/dev/null
source "$MGR"
# The manager sets `set -Eeuo pipefail` when sourced. This harness checks return
# codes explicitly, so -e must not abort it on a deliberate non-zero result.
trap - ERR
set +e
BASE_DIR="$TMP/etc"; BACKENDS_DIR="$BASE_DIR/backends"; FIREWALL_FILE="$BASE_DIR/firewall.nft"
INSTANCES_DIR="$BASE_DIR/instances"
install -d -m 0700 "$BASE_DIR" "$BACKENDS_DIR" "$INSTANCES_DIR"
systemctl() { return 0; }          # systemd is not the subject of this test

backend() { # $1=name $2=client $3=stats ; omit $3 to truncate before MTPROXY_STATS_PORT
  { printf 'MTPROXY_SECRET=%s\n' "$(printf 'a%.0s' {1..32})"
    printf 'MTPROXY_CLIENT_PORT=%s\n' "$2"
    [[ $# -ge 3 ]] && printf 'MTPROXY_STATS_PORT=%s\n' "$3"
    [[ $# -ge 3 ]] && printf 'MTPROXY_WORKERS=1\nMTPROXY_MAX_CONNECTIONS=100\n'
  } > "$BACKENDS_DIR/$1.env"
  chmod 0600 "$BACKENDS_DIR/$1.env"
}
run_rebuild() { ( rebuild_firewall ) >"$TMP/out.log" 2>&1; }   # die exits only the subshell
ports_in_file() { grep -o 'dport { [^}]*}' "$FIREWALL_FILE" 2>/dev/null | sed 's/dport { //;s/ *}//' ; }

# ---------- 1. healthy baseline: every configured port is covered ----------
backend a--default 23980 28980
backend b--default 23981 28981
if run_rebuild; then
  got="$(ports_in_file)"
  [[ "$got" == "23980,23981,28980,28981" ]] \
    && t_ok "tg7_healthy_covers_every_backend_port" \
    || t_bad "tg7_healthy_covers_every_backend_port: got '$got'"
else
  t_bad "tg7_healthy_rebuild_succeeds: rc!=0 on well-formed state"
fi
healthy="$(cat "$FIREWALL_FILE")"

# ---------- 2. second backend truncated before MTPROXY_STATS_PORT ----------
# The audited defect: b inherits a's stats port, so 28981 silently vanishes.
backend b--default 23981
if run_rebuild; then
  t_bad "tg7_truncated_second_fails_closed: rebuild reported success on damaged state"
  got="$(ports_in_file)"
  [[ "$got" == *28981* ]] || t_bad "tg7_truncated_second_no_port_loss: 28981 missing from '$got'"
else
  t_ok "tg7_truncated_second_fails_closed"
fi
[[ "$(cat "$FIREWALL_FILE")" == "$healthy" ]] \
  && t_ok "tg7_truncated_second_preserves_previous_ruleset" \
  || t_bad "tg7_truncated_second_preserves_previous_ruleset: valid isolation was replaced"
grep -q 'b--default' "$TMP/out.log" \
  && t_ok "tg7_truncated_second_names_damaged_file" \
  || t_bad "tg7_truncated_second_names_damaged_file: error does not identify the backend"
# no bleed: a's stats port must never be attributed to b
if grep -qE '^MTPROXY_STATS_PORT=' "$BACKENDS_DIR/b--default.env"; then
  t_bad "tg7_fixture_sanity_b_is_truncated"
else
  t_ok "tg7_fixture_sanity_b_is_truncated"
fi

# ---------- 3. repeated rebuild after a failure stays closed ----------
run_rebuild && t_bad "tg7_repeat_after_failure_stays_closed" || t_ok "tg7_repeat_after_failure_stays_closed"
[[ "$(cat "$FIREWALL_FILE")" == "$healthy" ]] \
  && t_ok "tg7_repeat_after_failure_preserves_ruleset" \
  || t_bad "tg7_repeat_after_failure_preserves_ruleset"

# ---------- 4. first backend truncated (sorts first) ----------
rm -f "$BACKENDS_DIR"/*.env
backend a--default 23980
backend b--default 23981 28981
run_rebuild && t_bad "tg7_truncated_first_fails_closed" || t_ok "tg7_truncated_first_fails_closed"
grep -q 'a--default' "$TMP/out.log" \
  && t_ok "tg7_truncated_first_names_damaged_file" \
  || t_bad "tg7_truncated_first_names_damaged_file: error does not identify the backend"

# ---------- 5. damaged file between two valid backends ----------
rm -f "$BACKENDS_DIR"/*.env
backend a--default 23980 28980
backend b--default 23981
backend c--default 23982 28982
run_rebuild && t_bad "tg7_truncated_middle_fails_closed" || t_ok "tg7_truncated_middle_fails_closed"

# ---------- 6. recovery: removing the damaged backend restores service ----------
rm -f "$BACKENDS_DIR/b--default.env"
if run_rebuild; then
  got="$(ports_in_file)"
  [[ "$got" == "23980,23982,28980,28982" ]] \
    && t_ok "tg7_recovers_after_damaged_backend_removed" \
    || t_bad "tg7_recovers_after_damaged_backend_removed: got '$got'"
else
  t_bad "tg7_recovers_after_damaged_backend_removed: rc!=0 on well-formed state"
fi

# ---------- 7. non-numeric / out-of-range port is rejected ----------
printf 'MTPROXY_CLIENT_PORT=23983\nMTPROXY_STATS_PORT=not-a-port\n' > "$BACKENDS_DIR/d--default.env"
run_rebuild && t_bad "tg7_invalid_port_fails_closed" || t_ok "tg7_invalid_port_fails_closed"

printf 'tg7: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
