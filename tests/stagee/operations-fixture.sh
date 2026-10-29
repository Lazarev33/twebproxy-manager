#!/usr/bin/env bash
# Stage E regression: everyday administration is safe and diagnostics are
# bounded and truthful.
#   E1  EOF/Ctrl-D/empty/interrupted input never confirms or selects anything:
#       yes/no answers NO, selections cancel, menus exit, numbers are decimal.
#   E2  status/overview/audit/diagnose/snapshot finish when probes hang.
#   E3  an unobservable state is UNKNOWN, never ERROR or OK; an incomplete
#       audit is not PASS; the dashboard shows each host's worst state.
#   E4  report bundles: no secrets/keys/credentials, unreadable logs skipped,
#       no staging or partial archive left behind, no unrelated routing tables.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-e-ops.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stagee/ops-harness.sh"
e_harness
export TWEBPROXY_RELAY_READY_WAIT=3 TWEBPROXY_DIAG_TIMEOUT=2
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
not() { ! "$@"; }
plain() { sed 's/\x1b\[[0-9;]*m//g' "$TMP/out"; }
show() { plain | grep -E '\[(x|!|\+)\]' | tail -n 3 | sed 's/^/  | /'; }
A=alpha.example B=beta.example C=gamma.example SEC=0123456789abcdef0123456789abcdef
# Bounded run of a manager command: $1=seconds, rest=command. rc 124 = it hung.
run() { local t="$1"; shift; timeout -k 3 "$t" bash -c 'source "$E_HARNESS"; e_harness; set -Eeuo pipefail; eval "$1"' e-run "$*" \
  < "${STDIN:-/dev/null}" > "$TMP/out" 2>&1; rc=$?; }
json_check() { jq -r --arg id "$1" '.checks[] | select(.id == $id) | .status' "$TMP/out" | sort -u | paste -sd, -; }   # $1=id

reset() {
  rm -rf "$INSTANCES_DIR" "$BACKENDS_DIR" "$SITES_DIR" "$BASE_DIR/.locks" "$TMP"/units/* "$TMP"/fail-* "$TMP"/hang-* \
    "$TMP"/state-* "$TMP"/public-cert-* "$TMP/custom" "$PROJECT_DIR" "$TMP"/*.reached "$TMP"/*.go "$TMP"/*.pid
  install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR" "$PROJECT_DIR" "$LOG_DIR" "$LOG_MANAGER_DIR" "$LOG_RUNTIME_DIR" \
    "$LOG_BUNDLE_DIR" "$LOG_FULL_DIR"   # as setup_logging leaves them
  install -d -m 0755 "$SITES_DIR"
}
seed_host() { # $1=host $2=index $3=tls [$4 $5] [$6=profiles: 1 default]
  d_seed_instance "$1" $((18080 + 2 * $2)) $((18081 + 2 * $2)) "$3" "${4:-}" "${5:-}"
  if [[ "${6:-1}" == 1 ]]; then
    c1_seed_profile "$1" main "$SEC" https $((23980 + $2)) $((28980 + $2))
    c1_run rebuild_profiles_json "$1" >/dev/null 2>&1
    "$TMP/bin/systemctl" start "twebproxy-mtproxy@$1--main.service"
  fi
  "$TMP/bin/systemctl" start "twebproxy@$1.service"
}
world() { # alpha: nginx-custom with a local certificate; beta: manual TLS
  reset
  d_make_cert "$TMP/custom/$A/fullchain.pem" "$TMP/custom/$A/privkey.pem" "$A"
  seed_host "$A" 0 nginx-custom "$TMP/custom/$A/fullchain.pem" "$TMP/custom/$A/privkey.pem"
  seed_host "$B" 1 manual
  # Relay/admin and stats listeners on loopback (backend listeners come from the unit model).
  printf 'LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:*\n' 18080 18081 18082 18083 28980 28981 > "$TMP/ss-extra"
  "$TMP/bin/systemctl" start twebproxy-firewall.service
  : > "$TMP/events"
}
new_tmp_entries() { comm -13 "$TMP/tmp.before" <(ls /tmp | sort) | grep -E '^(twebproxy-bundle|twebproxy-audit-cert|twebproxy-field)' || true; }
mark_tmp() { ls /tmp | sort > "$TMP/tmp.before"; }

# ---------- E1: input closed / Ctrl-D / malformed input ----------
world
# Prompts are used as at their call sites: yes/no as a condition, selections in $(...).
confirmed() { grep -qx CONFIRMED "$TMP/out"; }
run 10 'if yesno "Создать?" y; then echo CONFIRMED; fi'
check e1_eof_default_yes_is_no eval '[[ "$rc" -ne 124 ]] && ! confirmed'
run 10 'if yesno "Удалить?" n; then echo CONFIRMED; fi'
check e1_eof_default_no_is_no eval '[[ "$rc" -ne 124 ]] && ! confirmed'
printf 'y\n' > "$TMP/in"; STDIN="$TMP/in" run 10 'if yesno "Удалить?" n; then echo CONFIRMED; fi'
check e1_explicit_yes_still_yes confirmed
printf 'yes\n' > "$TMP/in"; STDIN="$TMP/in" run 10 'if yesno "Удалить?" n; then echo CONFIRMED; fi'
check e1_unexpected_word_is_no not confirmed
got() { sed -n 's/^got=//p' "$TMP/out"; }
run 10 'x="$(choose "Pick:" a b)"; echo "got=$x"'
check e1_choose_eof_cancels eval '[[ "$rc" -ne 0 && "$rc" -ne 124 && -z "$(got)" ]]'
printf '010\n' > "$TMP/in"; STDIN="$TMP/in" run 10 'x="$(choose "Pick:" 1 2 3 4 5 6 7 8 9 10)"; echo "got=$x"'
check e1_choose_leading_zero_is_decimal test "$(got)" = 10
printf '99999999999999999999\n' > "$TMP/in"; STDIN="$TMP/in" run 10 'x="$(choose "Pick:" a b)"; echo "got=$x"'
check e1_choose_huge_number_selects_nothing eval '[[ "$rc" -ne 0 && "$rc" -ne 124 && -z "$(got)" ]]'
run 10 'x="$(menu_choose "Menu:" Exit a b)"; echo "got=$x"'
check e1_menu_eof_means_back test "$(got)" = 0
run 10 'x="$(ask "Hostname" default.example)"; printf "got=%s\n" "$x"'
check e1_ask_eof_cancels_not_default eval '[[ "$rc" -ne 0 && "$rc" -ne 124 ]] && ! grep -q "got=default.example" "$TMP/out"'
run 10 'h="$(select_instance)"; echo "got=$h"'
check e1_select_eof_selects_no_host eval '[[ "$rc" -ne 0 && "$rc" -ne 124 && -z "$(got)" ]]'
run 20 'delete_instance_cmd'
check e1_delete_without_host_eof_deletes_nothing eval '[[ "$rc" -ne 124 && -f "$INSTANCES_DIR/$A/instance.env" && -f "$INSTANCES_DIR/$B/instance.env" ]]'
printf '%s\n' "$C" > "$TMP/in"; STDIN="$TMP/in" run 20 'add_instance_cmd'
check e1_add_wizard_eof_creates_nothing eval '[[ "$rc" -ne 0 && "$rc" -ne 124 && ! -e "$INSTANCES_DIR/$C" ]]'
before="$(cat "$INSTANCES_DIR/$A/profiles.d/main.env")"
run 20 "profile_rotate_cmd $A main"
check e1_rotate_eof_does_not_rotate eval '[[ "$rc" -ne 124 && "$(cat "$INSTANCES_DIR/$A/profiles.d/main.env")" == "$before" ]]'
run 20 'menu'
check e1_menu_eof_exits_cleanly test "$rc" -eq 0
check e1_menu_eof_no_spin test "$(plain | grep -c 'Enter a number')" -le 1
# Ctrl-C at the delete confirmation: nothing deleted.
mkfifo "$TMP/fifo"; exec {hold}<>"$TMP/fifo"
# Background jobs of a non-interactive shell start with SIGINT ignored: restore
# the default disposition before the manager starts, as a terminal would have it.
E_PIDFILE="$TMP/mgr.pid" python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
  bash -c 'source "$E_HARNESS"; e_harness; set -Eeuo pipefail; delete_instance_cmd "$1"' e-run "$A" \
  < "$TMP/fifo" > "$TMP/out" 2>&1 & p=$!
for ((i = 0; i < 100; i++)); do plain 2>/dev/null | grep -q 'will be deleted' && break; sleep 0.1; done; sleep 0.3
kill -INT "$(cat "$TMP/mgr.pid")" 2>/dev/null; wait "$p"; rc=$?; exec {hold}>&-
check e1_ctrl_c_at_confirmation_deletes_nothing eval '[[ "$rc" -ne 0 && -f "$INSTANCES_DIR/$A/instance.env" && -f "$BACKENDS_DIR/$A--main.env" ]]'

# ---------- E2: bounded read-only diagnostics ----------
world; : > "$TMP/hang-admin"; run 30 "OUTPUT_MODE=json status_cmd $A"
check e2_status_hung_relay_endpoint_bounded test "$rc" -ne 124
check e2_status_hung_relay_endpoint_reported eval '[[ "$(json_check relay.healthz)" == ERROR && "$(json_check relay.readyz)" == ERROR ]]'
world; : > "$TMP/hang-systemctl"; run 30 "OUTPUT_MODE=json status_cmd $A"
check e2_status_hung_systemd_bounded test "$rc" -ne 124
check e2_status_hung_systemd_is_unknown test "$(json_check relay.service.active)" = UNKNOWN
world; : > "$TMP/hang-systemctl"; run 40 'OUTPUT_MODE=json overview_cmd'
check e2_overview_hung_systemd_bounded test "$rc" -ne 124
world; : > "$TMP/hang-systemctl"; : > "$TMP/hang-nft"; run 60 "OUTPUT_MODE=json audit_cmd $A"
check e2_audit_hung_systemd_nft_bounded test "$rc" -ne 124
check e2_audit_hung_firewall_not_claimed_missing not test "$(json_check firewall.backend.boundary)" = ERROR
world; : > "$TMP/hang-journalctl"; : > "$TMP/hang-dig"; : > "$TMP/hang-nft"; run 60 "diagnose_cmd $A"
check e2_diagnose_hung_probes_bounded test "$rc" -ne 124
world; : > "$TMP/hang-hostnamectl"; : > "$TMP/hang-journalctl"; run 60 'logs_collect_cmd'
check e2_snapshot_hung_probes_bounded test "$rc" -ne 124

# ---------- E3: truthful status ----------
world; : > "$TMP/fail-systemctl"; run 30 "OUTPUT_MODE=json status_cmd $A"; show
check e3_status_systemd_unavailable_is_unknown test "$(json_check relay.service.active)" = UNKNOWN
check e3_status_systemd_unavailable_backend_unknown test "$(json_check profile.backend.service.active)" = UNKNOWN
check e3_status_exit_code_contract_kept test "$rc" -eq 0
world; run 30 "OUTPUT_MODE=json audit_cmd $A"
check e3_audit_public_cert_unavailable_no_false_mismatch not test "$(json_check tls.certificate.match)" = ERROR
check e3_audit_public_cert_unavailable_match_unknown test "$(json_check tls.certificate.match)" = UNKNOWN
world; printf 'not a certificate\n' > "$TMP/public-cert-$A"; run 30 "OUTPUT_MODE=json audit_cmd $A"
check e3_audit_unparseable_cert_not_expired test "$(json_check tls.public.certificate.validity)" = UNKNOWN
world; run 30 "audit_cmd $A"
check e3_audit_unverified_is_not_pass eval '! plain | grep -q "AUDIT RESULT: PASS"'
check e3_audit_unverified_is_incomplete eval 'plain | grep -q "AUDIT RESULT: INCOMPLETE"'
world; seed_host "$C" 2 manual "" "" 0; run 30 'collect_overview; tui_render_dashboard'
check e3_dashboard_host_without_profiles_not_ok eval 'plain | grep -E "^$C[[:space:]]" | grep -q "\[ERROR\]"'
check e3_dashboard_healthy_host_ok eval 'plain | grep -E "^$B[[:space:]]" | grep -q "\[OK\]"'
world; run 30 "OUTPUT_MODE=raw status_cmd $A"
check e3_raw_contract_header_kept eval 'head -n 2 "$TMP/out" | grep -q "^twebproxy.raw.v1	command=status	scope=hostname:$A" && sed -n 2p "$TMP/out" | grep -qx "id	status	severity	scope	source	observed	expected	message"'

# ---------- E4: logs and reports ----------
world; install -d -m 0700 "$PROJECT_DIR/logs/manager"
printf 'old session\nSecret:    dd%s\nlink https://t.me/webproxy?server=%s&secret=dd%s\n' "$SEC" "$A" "$SEC" > "$PROJECT_DIR/logs/manager/20260101-000000-old-1.log"
printf -- '-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAAS\n-----END PRIVATE KEY-----\nproxy https://ops:hunter2@proxy.example:3128/\n' >> "$PROJECT_DIR/logs/manager/20260101-000000-old-1.log"
mark_tmp; run 60 'logs_pack_cmd'; show
bundle="$(ls "$PROJECT_DIR"/logs/bundles/twebproxy-logs-*.tar.gz 2>/dev/null | head -n 1)"
check e4_pack_ok test "$rc" -eq 0 -a -n "$bundle"
mkdir -p "$TMP/x"; [[ -n "$bundle" ]] && tar -xzf "$bundle" -C "$TMP/x" 2>/dev/null
check e4_safe_bundle_no_secret not grep -rqE "$SEC" "$TMP/x"
check e4_safe_bundle_no_private_key not grep -rqE 'BEGIN PRIVATE KEY|MIIEvQIBADAN' "$TMP/x"
check e4_safe_bundle_no_url_credentials not grep -rq 'hunter2' "$TMP/x"
check e4_snapshot_no_unrelated_routing_tables not grep -rq 'table local' "$TMP/x"
check e4_pack_no_temp_left test -z "$(new_tmp_entries)"
world; install -d -m 0700 "$PROJECT_DIR/logs/runtime"; printf 'runtime\n' > "$PROJECT_DIR/logs/runtime/20260101-000000-gone.log"
: > "$TMP/fail-copy-20260101-000000-gone.log"; mark_tmp; run 60 'logs_pack_cmd'; show
check e4_unreadable_log_skipped_bundle_made eval '[[ "$rc" -eq 0 ]] && ls "$PROJECT_DIR"/logs/bundles/twebproxy-logs-*.tar.gz >/dev/null 2>&1'
check e4_unreadable_log_no_temp_left test -z "$(new_tmp_entries)"
world; mark_tmp
E_AT_TAR=tp E_PIDFILE="$TMP/mgr.pid" bash -c 'source "$E_HARNESS"; e_harness; set -Eeuo pipefail; logs_pack_cmd' e-run \
  < /dev/null > "$TMP/out" 2>&1 & p=$!
c1_wait_reached tp; kill -TERM "$(cat "$TMP/mgr.pid")" 2>/dev/null; : > "$TMP/tp.go"; wait "$p"; rc=$?; sleep 1
check e4_interrupted_pack_reported test "$rc" -ne 0
check e4_interrupted_pack_no_staging_left test -z "$(new_tmp_entries)"
check e4_interrupted_pack_no_partial_archive test -z "$(find "$PROJECT_DIR/logs/bundles" -name '*.partial' 2>/dev/null)"
world; mark_tmp; run 30 "OUTPUT_MODE=json audit_cmd $A"
check e4_audit_no_temp_left test -z "$(new_tmp_entries)"

printf 'e-operations: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
