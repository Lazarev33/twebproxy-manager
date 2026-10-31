#!/usr/bin/env bash
# Stage H regression: guided setup and everyday UX.
#   H1  quick setup asks only hostname, setup type, website and TLS; uses safe
#       defaults (auto ports, profile "default", new secret, https carrier,
#       STOCK); the advanced path still asks every value
#   H2  EOF, "no" and invalid input never create anything; an invalid hostname
#       is asked again (three attempts) with an actionable message
#   H3  first run: language selection, prerequisites, quick setup first
#   H4  main menu: task order, every item routes, 0/EOF return; network
#       compatibility is a separate advanced item
#   H5  Anti-DPI: STOCK default, six mode IDs with direction/overhead/IPv4-wide
#       effect/no-guarantee explanation, shared-IPv4 consent before any change
#   H6  client help after setup and in "show"; only the existing link forms
#   H7  compact status gives an actionable next step per problem; JSON unchanged
#   H8  RU/EN natural text, help, NO_COLOR
# Real prompts read stdin (tests/stagee/ops-harness.sh: models for systemd,
# nft, ip, dig, curl, Caddy/Nginx/certbot). The isolation audit is stubbed in
# the creation flows (covered by the C/E suites); nothing outside $TMP.
#
# Usage: ux-fixture.sh [path/to/twebproxy-manager.sh]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-h-ux.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stageh/ux-harness.sh"
h_harness
export TWEBPROXY_RELAY_READY_WAIT=3 TWEBPROXY_DIAG_TIMEOUT=2
pass=0; fail=0
check() { local name="$1"; shift; if "$@"; then printf 'PASS %s\n' "$name"; pass=$((pass+1)); else printf 'FAIL %s\n' "$name"; fail=$((fail+1)); fi; }
plain() { sed 's/\x1b\[[0-9;]*m//g' "$TMP/out"; }
has() { plain | grep -Fq -- "$1"; }
lacks() { ! plain | grep -Fq -- "$1"; }
cyr() { perl -CSD -ne 'BEGIN { $c = 0 } $c = 1 if /\p{Cyrillic}/; END { exit !$c }' "$TMP/out"; }
no_untranslated() { ! grep -q 'UNTRANSLATED_MESSAGE' "$TMP/out"; }
A=alpha.example C=gamma.example SEC=0123456789abcdef0123456789abcdef
# $1=seconds $2=language, rest=command (eval); stdin from $STDIN. rc 124 = hung.
run() { local t="$1" lang="$2"; shift 2; H_LANG="$lang" timeout -k 3 "$t" bash -c 'source "$H_HARNESS"; h_harness; set -Eeuo pipefail; eval "$1"' h-run "$*" \
  < "${STDIN:-/dev/null}" > "$TMP/out" 2>&1; rc=$?; }
# The same on a pseudo-terminal (first-run language selection needs a TTY).
run_tty() { local t="$1"; shift; printf '%s\n' "${@:2}" | H_LANG="" H_CMD="$1" timeout -k 3 "$t" script -qec \
  'bash -c '"'"'source "$H_HARNESS"; h_harness; set -Eeuo pipefail; eval "$H_CMD"'"'"'' /dev/null > "$TMP/out" 2>&1; rc=$?; }
answers() { printf '%s\n' "$@" > "$TMP/in"; STDIN="$TMP/in"; }
# Creation flows: everything real except the isolation audit and the DNS lookup of the new name.
CREATE='audit_instance_impl() { return 0; }; check_dns_for_host() { return 0; }; add_instance_cmd'

reset() {
  rm -rf "$INSTANCES_DIR" "$BACKENDS_DIR" "$SITES_DIR" "$BASE_DIR/.locks" "$BASE_DIR/dpi" "$TMP"/units/* "$PROJECT_DIR" "$LANGUAGE_FILE"
  install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR" "$PROJECT_DIR"
  install -d -m 0755 "$SITES_DIR"
}
seed_host() { # $1=host $2=index $3=tls
  d_seed_instance "$1" $((18080 + 2 * $2)) $((18081 + 2 * $2)) "$3"
  c1_seed_profile "$1" main "$SEC" https $((23980 + $2)) $((28980 + $2))
  c1_run rebuild_profiles_json "$1" >/dev/null 2>&1
  "$TMP/bin/systemctl" start "twebproxy-mtproxy@$1--main.service" "twebproxy@$1.service"
}
core_present() { install -d -m 0755 "$LIBEXEC_DIR" "$SYSTEMD_DIR"; printf '#!/bin/sh\n' > "$MTPROXY_BIN"; chmod 0755 "$MTPROXY_BIN"; : > "$SYSTEMD_DIR/twebproxy@.service"; }
core_absent() { rm -f "$MTPROXY_BIN" "$SYSTEMD_DIR/twebproxy@.service"; }
created() { [[ -f "$INSTANCES_DIR/$C/instance.env" ]]; }
nothing_created() { [[ ! -e "$INSTANCES_DIR/$C" ]] && ! ls "$BACKENDS_DIR" 2>/dev/null | grep -q "^$C--"; }
profile_value() { sed -n "s/^$2=//p" "$INSTANCES_DIR/$C/profiles.d/$1.env" 2>/dev/null | head -n1; }

# ================= H1 quick and advanced setup ==============================
reset; core_present
# On a pseudo-terminal, so that every read -p prompt is visible in the output.
# hostname, setup type 1 (quick), site 1, TLS 1 (Caddy), plan confirmation (Enter)
run_tty 60 "$CREATE" "$C" 1 1 1 ""
check "h1_quick_creates (rc=$rc)" eval 'test "$rc" -eq 0 && created'
check h1_quick_hostname_prompt_visible has 'WEB Proxy hostname'
check h1_quick_asks_setup_type has 'Setup type:'
check h1_quick_recommends_quick has 'Quick (recommended)'
check h1_quick_recommends_caddy has 'Caddy — automatic HTTPS certificate (recommended)'
check h1_quick_honest_placeholder has 'Temporary placeholder page'
check h1_quick_skips_port_questions lacks 'ports automatically'
check h1_quick_skips_profile_questions eval "lacks 'Profile/secret name' && lacks 'Carrier mode' && lacks 'MTProxy workers' && lacks 'Maximum connections' && lacks 'Generate a new'"
check h1_quick_default_profile test -f "$INSTANCES_DIR/$C/profiles.d/default.env"
check h1_quick_default_carrier test "$(profile_value default CARRIER_MODE)" = https
check h1_quick_new_secret eval '[[ "$(profile_value default SECRET)" =~ ^[0-9a-f]{32}$ ]]'
check h1_quick_plan_states_stock has 'Network mode:   STOCK'
check h1_quick_stock_no_dpi_state test ! -e "$BASE_DIR/dpi"
check h1_quick_client_help has 'How to connect Telegram'
check h1_quick_link has "https://t.me/webproxy?server=$C&secret="
check h1_quick_next_steps has "twebproxy status $C"
check h1_quick_no_untranslated no_untranslated

reset; core_present
# hostname, setup type 2 (advanced), internal ports auto (Enter), site 1, TLS 4 (manual),
# profile name, generate secret, carrier 2, profile ports auto, workers, max connections, confirm
run_tty 60 "$CREATE" "$C" 2 "" 1 4 team "" 2 "" "" "" ""
check "h1_advanced_creates (rc=$rc)" eval 'test "$rc" -eq 0 && created'
check h1_advanced_asks_ports has 'ports automatically'
check h1_advanced_asks_profile eval "has 'Profile/secret name' && has 'Carrier mode' && has 'MTProxy workers' && has 'Maximum connections'"
check h1_advanced_profile_named test -f "$INSTANCES_DIR/$C/profiles.d/team.env"
check h1_advanced_carrier_choice test "$(profile_value team CARRIER_MODE)" = https-lanes
check h1_advanced_plan_states_stock has 'Network mode:   STOCK'

# ================= H2 EOF, no, invalid input ================================
reset; core_present
answers "$C"; run 30 en "$CREATE"
check "h2_eof_at_setup_type_creates_nothing (rc=$rc)" eval 'test "$rc" -ne 0 -a "$rc" -ne 124 && nothing_created'
check h2_eof_no_untranslated no_untranslated
answers "$C" 1; run 30 en "$CREATE"
check "h2_eof_at_website_creates_nothing (rc=$rc)" eval 'test "$rc" -ne 0 -a "$rc" -ne 124 && nothing_created'
answers "$C" 1 1 1; run 30 en "$CREATE"
check "h2_eof_at_confirmation_creates_nothing (rc=$rc)" eval 'test "$rc" -ne 124 && nothing_created'
answers "$C" 1 1 1 n; run 30 en "$CREATE"
check "h2_no_at_confirmation_creates_nothing (rc=$rc)" eval 'test "$rc" -ne 124 && nothing_created'
answers "$C" 1 1 1 "" n; run 30 en 'audit_instance_impl() { return 0; }; check_dns_for_host() { return 1; }; add_instance_cmd'
check "h2_dns_mismatch_default_no_creates_nothing (rc=$rc)" eval 'test "$rc" -ne 0 -a "$rc" -ne 124 && nothing_created'
run_tty 60 "$CREATE" 'Bad_Host!' "$C" 1 1 1 ""
check "h2_invalid_hostname_asked_again (rc=$rc)" eval 'test "$rc" -eq 0 && created'
check h2_invalid_hostname_actionable has 'proxy.example.com'
reset; core_present
run_tty 30 "$CREATE" 'Bad_Host!' 'https://x.example' 'nodot'
check "h2_three_invalid_hostnames_abort (rc=$rc)" eval 'test "$rc" -ne 0 -a "$rc" -ne 124 && nothing_created && ! ls "$INSTANCES_DIR" | grep -q .'
check h2_invalid_hostname_three_prompts test "$(plain | grep -c 'WEB Proxy hostname (without')" -eq 3

# ================= H3 first run ==============================================
reset; core_absent
run_tty 30 'menu' 1 0
check "h3_first_run_language_prompt (rc=$rc)" has 'Select language / Выберите язык'
check h3_first_run_language_saved test "$(cat "$LANGUAGE_FILE" 2>/dev/null)" = en
check h3_first_run_prerequisites eval "has 'DNS A record' && has 'TCP 443' && has 'TCP 80'"
check h3_first_run_quick_setup_first eval "plain | grep -E '^\s*\[1\]' | tail -n1 | grep -q 'Quick setup'"
check h3_first_run_core_only_second eval "plain | grep -E '^\s*\[2\]' | tail -n1 | grep -q 'core only'"
check "h3_first_run_exit (rc=$rc)" test "$rc" -eq 0
rm -f "$LANGUAGE_FILE"; run_tty 30 'menu' 2 0
check h3_first_run_russian has 'Быстрая настройка'
check h3_first_run_russian_prerequisites has 'DNS-записью A'
check h3_first_run_russian_saved test "$(cat "$LANGUAGE_FILE" 2>/dev/null)" = ru

# ================= H4 main menu ==============================================
reset; core_present; seed_host "$A" 0 manual
STUBS='menu_connect() { echo ROUTE:connect; }; menu_status_statistics() { echo ROUTE:status; }; menu_web_proxy() { echo ROUTE:instances; }
  menu_profiles() { echo ROUTE:profiles; }; menu_diagnostics() { echo ROUTE:diagnostics; }; menu_maintenance() { echo ROUTE:maintenance; }
  menu_network_compatibility() { echo ROUTE:compatibility; }; menu_settings() { echo ROUTE:settings; }; clear() { :; }'
expect=(connect status instances profiles diagnostics maintenance compatibility settings)
for n in 1 2 3 4 5 6 7 8; do
  answers "$n" 0; run 30 en "$STUBS; menu"
  check "h4_main_menu_item_${n}_routes_${expect[n-1]}" eval "grep -qx 'ROUTE:${expect[n-1]}' '$TMP/out' && test $rc -eq 0"
done
answers; run 30 en "$STUBS; menu"
check "h4_main_menu_eof_exits (rc=$rc)" test "$rc" -eq 0
answers 0; run 30 en 'clear() { :; }; menu_network_compatibility'
check "h4_compatibility_zero_returns (rc=$rc)" test "$rc" -eq 0
answers 0; run 30 en 'clear() { :; }; menu_settings'
check h4_settings_has_no_duplicate_compatibility lacks 'Network compatibility'

# ================= H5 Anti-DPI ===============================================
run 30 en 'dpi_list_methods_cmd'
for id in stock window1152 mss88 nfqws window1152_nfqws mss88_nfqws; do
  check "h5_list_has_$id" eval "plain | grep -Eq '^$id {2,}'"
done
check h5_list_six_ids test "$(plain | grep -Ec '^(stock|window1152|mss88|nfqws|window1152_nfqws|mss88_nfqws) {2,}')" -eq 6
check h5_list_stock_default has 'No traffic modification; production default.'
check h5_list_direction has 'Direction:'
check h5_list_overhead has 'Overhead:'
check h5_list_ipv4_wide has 'every HTTPS connection from the same public IPv4'
check h5_list_no_guarantee has 'No mode guarantees'
check h5_list_revert has 'twebproxy dpi disable'
check h5_list_no_best_mode eval "! plain | grep -Eiq 'best (mode|method)|recommended mode: (window|mss|nfqws)'"
run 30 ru 'dpi_list_methods_cmd'
check h5_list_russian cyr
check h5_list_russian_no_english_prose eval "! LC_ALL=C grep -Eqi '\\b(live|legacy|lifecycle|Audit|renewal|Offline|helper|receive window|traffic|scope|shared)\\b' '$TMP/out'"
DPI_STUBS='clear() { :; }; dpi_resolve_ipv4() { printf "198.51.100.10"; }; dpi_hosts_for_ipv4() { printf "%s\n" "$@" >/dev/null; printf "alpha.example\n"; }
  dpi_set_cmd() { echo "DPI_SET $*"; }'
answers 3 1 "" "" 0; run 30 en "$DPI_STUBS; menu_network_compatibility"
check h5_tui_intro_stock_default has 'STOCK (default)'
check h5_tui_methods_explained has 'window1152 — experimental'
check h5_tui_consent_shown has 'every HTTPS flow sourced from 198.51.100.10:443'
check h5_tui_consent_default_no eval "lacks 'DPI_SET' && has 'No changes applied.'"
answers 3 1 y "" 0; run 30 en "$DPI_STUBS; menu_network_compatibility"
check h5_tui_revert_tip has 'twebproxy dpi disable alpha.example'
check h5_tui_consent_yes_applies has 'DPI_SET alpha.example window1152 --accept-shared-scope'
answers 3 1; run 30 en "$DPI_STUBS; menu_network_compatibility"
check h5_tui_consent_eof_no_change eval "lacks 'DPI_SET' && test $rc -ne 124"

# ================= H6 client help ============================================
run 30 en "show_instance_cmd $A"
check h6_show_help has 'How to connect Telegram'
check h6_show_web_link has "https://t.me/webproxy?server=$A&secret=$SEC"
check h6_show_tg_link has "tg://webproxy?server=$A&secret=$SEC"
check h6_show_check_site has "https://$A/"
check h6_show_troubleshooting has "twebproxy status $A"
check h6_show_client_support_honest has 'does not check client versions'
check h6_show_no_other_urls eval "! plain | grep -oE '(https?|tg)://[^ )\`]+' | grep -vE '^(https://t\\.me/webproxy\\?server=|tg://webproxy\\?server=|https://$A/)' | grep -q ."
run 30 ru "show_instance_cmd $A"
check h6_show_russian has 'Как подключить Telegram'
check h6_show_russian_no_untranslated no_untranslated

# ================= H7 actionable status ======================================
"$TMP/bin/systemctl" stop "twebproxy@$A.service" >/dev/null 2>&1
run 30 en "collect_status $A; tui_render_status $A"
check h7_status_problem_shown eval "plain | grep -q 'relay.service.active'"
check h7_status_hint_repair has "twebproxy repair $A"
run 30 ru "collect_status $A; tui_render_status $A"
check h7_status_hint_russian eval "has 'twebproxy repair $A' && cyr"
# One next step per check family; an UNKNOWN TLS state is "not confirmed", never "failed".
run 30 en "for c in relay.healthz frontend.service.active tls.certificate.summary profiles.present firewall.backend profile.backend.service.active other.check; do tui_check_hint \$c $A; echo; done"
check h7_hint_families eval "has 'twebproxy repair $A (details: twebproxy diagnose $A)' && has 'web server (Caddy/Nginx)' && has 'certificate is not confirmed' && has 'twebproxy cert-status $A' && has 'twebproxy profile-add $A' && has 'twebproxy audit $A' && has 'A profile backend needs attention' && has 'twebproxy status $A --verbose'"
check h7_hint_tls_not_failed lacks 'check failed'
run 30 en "OUTPUT_MODE=json; collect_status $A; tcore_render_json"
check h7_json_has_no_hint eval "jq -e . '$TMP/out' >/dev/null && ! grep -q 'twebproxy repair' '$TMP/out'"
"$TMP/bin/systemctl" start "twebproxy@$A.service" >/dev/null 2>&1

# ================= H8 help, localization, NO_COLOR ===========================
# The help text is printed, never executed: an unquoted heredoc would run
# `sudo twebproxy` (it did once). Shell-function tripwires record any such run.
TRIP='sudo() { printf "EXECUTED:sudo %s\n" "$*"; }; twebproxy() { printf "EXECUTED:twebproxy %s\n" "$*"; }'
run 30 en "$TRIP; usage"
check h8_help_quick_start has 'Quick start'
check h8_help_english_only eval '! cyr'
check h8_help_text_literal eval "has 'run \"sudo twebproxy\" and choose' && has '\"twebproxy show HOSTNAME\"' && has '\"twebproxy status HOSTNAME\"' && test $rc -eq 0"
check h8_help_runs_nothing lacks 'EXECUTED:'
run 30 ru "$TRIP; usage"
check h8_help_russian_quick_start has 'Быстрый старт'
check h8_help_russian_literal eval "has '«sudo twebproxy»' && has '«twebproxy show HOSTNAME»' && ! grep -q 'EXECUTED:' '$TMP/out'"
run 30 en "enable_colors; NO_COLOR=1; disable_colors; show_instance_cmd $A; collect_status $A; tui_render_status $A; dpi_list_methods_cmd"
check h8_no_color_no_ansi eval "! grep -q \$'\\033' '$TMP/out'"

printf 'ux-fixture: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
